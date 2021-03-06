{-# LANGUAGE DeriveDataTypeable, OverloadedStrings #-}
module Lib.FSHook
  ( getLdPreloadPath
  , FSHook
  , with

  , KeepsOldContent(..), OutputEffect(..), OutputBehavior(..)
  , Input(..)
  , DelayedOutput(..), UndelayedOutput
  , Protocol.OutFilePath(..), Protocol.OutEffect(..)
  , FSAccessHandlers(..)

  , AccessType(..), AccessDoc

  , runCommand, timedRunCommand
  ) where

import Control.Applicative (Applicative(..), (<$>))
import Control.Concurrent (ThreadId, myThreadId, killThread)
import Control.Concurrent.MVar
import Control.Exception.Async (handleSync)
import Control.Monad
import Data.ByteString (ByteString)
import Data.IORef
import Data.Map.Strict (Map)
import Data.Maybe (maybeToList)
import Data.Monoid ((<>))
import Data.String (IsString(..))
import Data.Time (NominalDiffTime)
import Data.Typeable (Typeable)
import Lib.Argv0 (getArgv0)
import Lib.ByteString (unprefixed)
import Lib.ColorText (ColorText)
import Lib.FSHook.AccessType (AccessType(..))
import Lib.FSHook.OutputBehavior (KeepsOldContent(..), OutputEffect(..), OutputBehavior(..))
import Lib.FSHook.Protocol (IsDelayed(..))
import Lib.FilePath (FilePath, (</>), takeDirectory, canonicalizePath)
import Lib.Fresh (Fresh)
import Lib.IORef (atomicModifyIORef'_, atomicModifyIORef_)
import Lib.Printer (Printer)
import Lib.Sock (recvFrame, recvLoop_, withUnixStreamListener)
import Lib.TimeIt (timeIt)
import Network.Socket (Socket)
import Paths_buildsome (getDataFileName)
import Prelude hiding (FilePath)
import System.IO (hPutStrLn, stderr)
import qualified Control.Exception as E
import qualified Data.ByteString.Char8 as BS8
import qualified Data.Map.Strict as M
import qualified Lib.AsyncContext as AsyncContext
import qualified Lib.FSHook.OutputBehavior as OutputBehavior
import qualified Lib.FSHook.Protocol as Protocol
import qualified Lib.Fresh as Fresh
import qualified Lib.Printer as Printer
import qualified Lib.Process as Process
import qualified Network.Socket as Sock
import qualified Network.Socket.ByteString as SockBS
import qualified System.Posix.ByteString as Posix

type AccessDoc = ColorText

type JobId = ByteString

data Input = Input
  { inputAccessType :: AccessType
  , inputPath :: FilePath
  } deriving (Eq, Ord, Show)

data DelayedOutput = DelayedOutput
-- TODO: Rename to delayedOutput...
  { outputBehavior :: OutputBehavior
  , outputPath :: FilePath
  } deriving (Eq, Ord, Show)

type UndelayedOutput = Protocol.OutFilePath

data FSAccessHandlers = FSAccessHandlers
  { delayedFSAccessHandler   :: AccessDoc -> [Input] -> [DelayedOutput] -> IO ()
  , undelayedFSAccessHandler :: AccessDoc -> [Input] -> [UndelayedOutput] -> IO ()
  }

type JobLabel = ColorText

data RunningJob = RunningJob
  { jobLabel :: JobLabel
  , jobActiveConnections :: IORef (Map Int (ThreadId, MVar ()))
  , jobFreshConnIds :: Fresh Int
  , jobThreadId :: ThreadId
  , jobFSAccessHandlers :: FSAccessHandlers
  , jobRootFilter :: FilePath
  }

data Job = KillingJob JobLabel | CompletedJob JobLabel | LiveJob RunningJob

data FSHook = FSHook
  { fsHookRunningJobs :: IORef (Map JobId Job)
  , fsHookFreshJobIds :: Fresh Int
  , fsHookLdPreloadPath :: FilePath
  , fsHookServerAddress :: FilePath
  }

data ProtocolError = ProtocolError String deriving (Typeable)
instance E.Exception ProtocolError
instance Show ProtocolError where
  show (ProtocolError msg) = "ProtocolError: " ++ msg

serve :: Printer -> FSHook -> Socket -> IO ()
serve printer fsHook conn = do
  mHelloLine <- recvFrame conn
  case mHelloLine of
    Nothing -> E.throwIO $ ProtocolError "Unexpected EOF"
    Just helloLine ->
      case unprefixed Protocol.helloPrefix helloLine of
        Nothing ->
          E.throwIO $ ProtocolError $ concat
          [ "Bad hello message from connection: ", show helloLine, " expected: "
          , show Protocol.helloPrefix, " (check your fs_override.so installation)" ]
        Just pidJobId -> do
          runningJobs <- readIORef (fsHookRunningJobs fsHook)
          case M.lookup jobId runningJobs of
            Nothing -> do
              let jobIds = M.keys runningJobs
              E.throwIO $ ProtocolError $ concat ["Bad slave id: ", show jobId, " mismatches all: ", show jobIds]
            Just (KillingJob _label) ->
              -- New connection created in the process of killing connections, ignore it
              return ()
            Just (LiveJob job) -> handleJobConnection fullTidStr conn job
            Just (CompletedJob label) ->
              E.throwIO $ ProtocolError $ concat
              -- Main/parent process completed, and leaked some subprocess
              -- which connected again!
              [ "Job: ", BS8.unpack jobId, "(", BS8.unpack (Printer.render printer label)
              , ") received new connections after formal completion!"]
          where
            fullTidStr = concat [BS8.unpack pidStr, ":", BS8.unpack tidStr]
            [pidStr, tidStr, jobId] = BS8.split ':' pidJobId

-- Except thread killed
printRethrowExceptions :: String -> IO a -> IO a
printRethrowExceptions msg =
  E.handle $ \e -> do
    case E.fromException e of
      Just E.ThreadKilled -> return ()
      _ -> hPutStrLn stderr $ msg ++ show e
    E.throwIO e

with :: Printer -> FilePath -> (FSHook -> IO a) -> IO a
with printer ldPreloadPath body = do
  pid <- Posix.getProcessID
  freshJobIds <- Fresh.new 0
  let serverFilename = "/tmp/fshook-" <> BS8.pack (show pid)
  withUnixStreamListener serverFilename $ \listener -> do
    runningJobsRef <- newIORef M.empty
    let
      fsHook = FSHook
        { fsHookRunningJobs = runningJobsRef
        , fsHookFreshJobIds = freshJobIds
        , fsHookLdPreloadPath = ldPreloadPath
        , fsHookServerAddress = serverFilename
        }
    AsyncContext.new $ \ctx -> do
      _ <-
        AsyncContext.spawn ctx $ printRethrowExceptions "BUG: Listener loop threw exception: " $ forever $
        do
          (conn, _srcAddr) <- Sock.accept listener
          AsyncContext.spawn ctx $
            -- Job connection may fail when the process is killed
            -- during a send-message, which may cause a protocol error
            printRethrowExceptions "Job connection failed: " $
            serve printer fsHook conn
            `E.finally` Sock.close conn
      body fsHook

{-# INLINE sendGo #-}
sendGo :: Socket -> IO ()
sendGo conn = void $ SockBS.send conn (BS8.pack "GO")

{-# INLINE handleJobMsg #-}
handleJobMsg :: String -> Socket -> RunningJob -> Protocol.Msg -> IO ()
handleJobMsg _tidStr conn job (Protocol.Msg isDelayed func) =
  case func of
    -- TODO: If any of these outputs are NOT also mode-only inputs on
    -- their file paths, don't use handleOutputs so that we don't
    -- report them as inputs

    -- outputs
    -- TODO: Handle truncation flag
    Protocol.OpenW outPath _openWMode _create Protocol.OpenNoTruncate
                                -> handleOutputs [(OutputBehavior.fileChanger KeepsOldContent, outPath)]
    Protocol.OpenW outPath _openWMode _create Protocol.OpenTruncate
                                -> handleOutputs [(OutputBehavior.fileChanger KeepsNoOldContent, outPath)]
    Protocol.Creat outPath _    -> handleOutputs [(OutputBehavior.fileChanger KeepsNoOldContent, outPath)]
    Protocol.Rename a b         -> handleOutputs [ (OutputBehavior.existingFileChanger KeepsNoOldContent, a)
                                                 , (OutputBehavior.fileChanger KeepsOldContent, b) ]
    Protocol.Unlink outPath     -> handleOutputs [(OutputBehavior.existingFileChanger KeepsNoOldContent, outPath)]
    Protocol.Truncate outPath _ -> handleOutputs [(OutputBehavior.existingFileChanger KeepsNoOldContent, outPath)]
    Protocol.Chmod outPath _    -> handleOutputs [(OutputBehavior.existingFileChanger KeepsOldContent, outPath)]
    Protocol.Chown outPath _ _  -> handleOutputs [(OutputBehavior.existingFileChanger KeepsOldContent, outPath)]
    Protocol.MkNod outPath _ _  -> handleOutputs [(OutputBehavior.nonExistingFileChanger KeepsNoOldContent, outPath)] -- TODO: Special mkNod handling?
    Protocol.MkDir outPath _    -> handleOutputs [(OutputBehavior.nonExistingFileChanger KeepsNoOldContent, outPath)]
    Protocol.RmDir outPath      -> handleOutputs [(OutputBehavior.existingFileChanger KeepsOldContent {- TODO: if we know rmdir will fail (not empty) then no effect at all, and we can use KeepsNoOldContent -}, outPath)]

    -- I/O
    Protocol.SymLink target linkPath ->
      -- TODO: We don't actually read the input here, but we don't
      -- handle symlinks correctly yet, so better be false-positive
      -- than false-negative
      handle
        [ Input AccessTypeFull target ]
        [ (OutputBehavior.nonExistingFileChanger KeepsNoOldContent, linkPath) ]
    Protocol.Link src dest -> error $ unwords ["Hard links not supported:", show src, "->", show dest]

    -- inputs
    Protocol.OpenR path            -> handleInput AccessTypeFull path
    Protocol.Access path _mode     -> handleInput AccessTypeModeOnly path
    Protocol.Stat path             -> handleInput AccessTypeStat path
    Protocol.LStat path            -> handleInput AccessTypeStat path
    Protocol.OpenDir path          -> handleInput AccessTypeFull path
    Protocol.ReadLink path         -> handleInput AccessTypeFull path
    Protocol.Exec path             -> handleInput AccessTypeFull path
    Protocol.ExecP mPath attempted ->
      handleInputs $
      map (Input AccessTypeFull) (maybeToList mPath) ++
      map (Input AccessTypeModeOnly) attempted
  where
    handlers = jobFSAccessHandlers job
    handleDelayed   inputs outputs = wrap $ delayedFSAccessHandler handlers actDesc inputs outputs
    handleUndelayed inputs outputs = wrap $ undelayedFSAccessHandler handlers actDesc inputs outputs
    wrap = wrapHandler job conn isDelayed
    actDesc = fromString (Protocol.showFunc func) <> " done by " <> jobLabel job
    handleInput accessType path = handleInputs [Input accessType path]
    handleInputs inputs =
      case isDelayed of
      NotDelayed -> handleUndelayed inputs []
      Delayed    -> handleDelayed   inputs []
    inputOfOutputPair (_behavior, Protocol.OutFilePath path _effect) =
      Input AccessTypeModeOnly path
    mkDelayedOutput ( behavior, Protocol.OutFilePath path _effect) =
      DelayedOutput behavior path
    handleOutputs = handle []
    handle inputs outputPairs =
      case isDelayed of
      NotDelayed -> handleUndelayed allInputs $ map snd outputPairs
      Delayed -> handleDelayed allInputs $ map mkDelayedOutput outputPairs
      where
        allInputs = inputs ++ map inputOfOutputPair outputPairs

wrapHandler :: RunningJob -> Socket -> IsDelayed -> IO () -> IO ()
wrapHandler job conn isDelayed handler =
  forwardExceptions $ do
    handler
    -- Intentionally avoid sendGo if jobFSAccessHandler failed. It
    -- means we disallow the effect.
    case isDelayed of
      Delayed -> sendGo conn
      NotDelayed -> return ()
  where
    forwardExceptions = handleSync $ \e@E.SomeException {} -> E.throwTo (jobThreadId job) e

withRegistered :: Ord k => IORef (Map k a) -> k -> a -> IO r -> IO r
withRegistered registry key val =
  E.bracket_ register unregister
  where
    register = atomicModifyIORef_ registry $ M.insert key val
    unregister = atomicModifyIORef_ registry $ M.delete key

handleJobConnection :: String -> Socket -> RunningJob -> IO ()
handleJobConnection tidStr conn job = do
  -- This lets us know for sure that by the time the slave dies,
  -- we've seen its connection
  connId <- Fresh.next $ jobFreshConnIds job
  tid <- myThreadId

  connFinishedMVar <- newEmptyMVar
  (`E.finally` putMVar connFinishedMVar ()) $
    withRegistered (jobActiveConnections job) connId (tid, connFinishedMVar) $ do
      sendGo conn
      recvLoop_ (handleJobMsg tidStr conn job <=< Protocol.parseMsg) conn

mkEnvVars :: FSHook -> FilePath -> JobId -> Process.Env
mkEnvVars fsHook rootFilter jobId =
  (map . fmap) BS8.unpack
  [ ("LD_PRELOAD", fsHookLdPreloadPath fsHook)
  , ("DYLD_FORCE_FLAT_NAMESPACE", "1")
  , ("DYLD_INSERT_LIBRARIES", fsHookLdPreloadPath fsHook)
  , ("BUILDSOME_MASTER_UNIX_SOCKADDR", fsHookServerAddress fsHook)
  , ("BUILDSOME_JOB_ID", jobId)
  , ("BUILDSOME_ROOT_FILTER", rootFilter)
  ]

timedRunCommand ::
  FSHook -> FilePath -> (Process.Env -> IO r) -> ColorText ->
  FSAccessHandlers -> IO (NominalDiffTime, r)
timedRunCommand fsHook rootFilter cmd label fsAccessHandlers = do
  pauseTimeRef <- newIORef 0
  let
    addPauseTime delta = atomicModifyIORef'_ pauseTimeRef (+delta)
    measurePauseTime act = do
      (time, res) <- timeIt act
      addPauseTime time
      return res
    wrappedFsAccessHandler isDelayed handler accessDoc inputs outputs = do
      let act = handler accessDoc inputs outputs
      case isDelayed of
        Delayed -> measurePauseTime act
        NotDelayed -> act
    wrappedFsAccessHandlers =
      FSAccessHandlers
        (wrappedFsAccessHandler Delayed delayed)
        (wrappedFsAccessHandler NotDelayed undelayed)
  (time, res) <-
    runCommand fsHook rootFilter (timeIt . cmd) label wrappedFsAccessHandlers
  subtractedTime <- (time-) <$> readIORef pauseTimeRef
  return (subtractedTime, res)
  where
    FSAccessHandlers delayed undelayed = fsAccessHandlers

withRunningJob :: FSHook -> JobId -> RunningJob -> IO r -> IO r
withRunningJob fsHook jobId job body = do
  setJob (LiveJob job)
  (body <* setJob (CompletedJob (jobLabel job)))
    `E.onException` setJob (KillingJob (jobLabel job))
  where
    registry = fsHookRunningJobs fsHook
    setJob = atomicModifyIORef_ registry . M.insert jobId

runCommand ::
  FSHook -> FilePath -> (Process.Env -> IO r) -> ColorText ->
  FSAccessHandlers -> IO r
runCommand fsHook rootFilter cmd label fsAccessHandlers = do
  activeConnections <- newIORef M.empty
  freshConnIds <- Fresh.new 0
  jobIdNum <- Fresh.next $ fsHookFreshJobIds fsHook
  tid <- myThreadId

  let jobId = BS8.pack ("cmd" ++ show jobIdNum)
      job = RunningJob
            { jobLabel = label
            , jobActiveConnections = activeConnections
            , jobFreshConnIds = freshConnIds
            , jobThreadId = tid
            , jobRootFilter = rootFilter
            , jobFSAccessHandlers = fsAccessHandlers
            }
  -- Don't leak connections still running our handlers once we leave!
  let onActiveConnections f = mapM_ f . M.elems =<< readIORef activeConnections
  (`E.finally` onActiveConnections awaitConnection) $
    (`E.onException` onActiveConnections killConnection) $
    withRunningJob fsHook jobId job $
    cmd (mkEnvVars fsHook rootFilter jobId)
  where
    killConnection (tid, _mvar) = killThread tid
    awaitConnection (_tid, mvar) = readMVar mvar

data CannotFindOverrideSharedObject = CannotFindOverrideSharedObject deriving (Show, Typeable)
instance E.Exception CannotFindOverrideSharedObject

assertLdPreloadPathExists :: FilePath -> IO ()
assertLdPreloadPathExists path = do
  e <- Posix.fileExist path
  unless e $ E.throwIO CannotFindOverrideSharedObject

getLdPreloadPath :: Maybe FilePath -> IO FilePath
getLdPreloadPath (Just path) = do
  ldPreloadPath <- canonicalizePath path
  assertLdPreloadPathExists ldPreloadPath
  return ldPreloadPath
getLdPreloadPath Nothing = do
  installedFilePath <- BS8.pack <$> (getDataFileName . BS8.unpack) fileName
  installedExists <- Posix.fileExist installedFilePath
  if installedExists
    then return installedFilePath
    else do
      argv0 <- getArgv0
      let nearExecPath = takeDirectory argv0 </> fileName
      assertLdPreloadPathExists nearExecPath
      return nearExecPath
  where
    fileName = "cbits/fs_override.so"
