module Buildsome.MemoParseMakefile
  ( IsHit(..), memoParse
  ) where

import Buildsome.Db (Db)
import Buildsome.FileContentDescCache (fileContentDescOfStat)
import Control.Applicative ((<$>))
import Control.DeepSeq (rnf)
import Data.Map (Map)
import Lib.FileDesc (FileContentDesc)
import Lib.FilePath (FilePath)
import Lib.Makefile (Makefile, Vars)
import Prelude hiding (FilePath)
import qualified Buildsome.Db as Db
import qualified Buildsome.Meddling as Meddling
import qualified Control.Exception as E
import qualified Data.Map as Map
import qualified Lib.Directory as Dir
import qualified Lib.Makefile as Makefile
import qualified Lib.Makefile.Monad as MakefileMonad
import qualified Lib.Makefile.Parser as MakefileParser
import qualified System.Posix.ByteString as Posix

mkFileDesc :: Db -> FilePath -> Maybe Posix.FileStatus -> IO (Db.FileDesc () FileContentDesc)
mkFileDesc _ _ Nothing = return $ Db.FileDescNonExisting ()
mkFileDesc db path (Just stat) = Db.FileDescExisting <$> fileContentDescOfStat db path stat

parse :: Db -> FilePath -> Vars -> IO (Map FilePath (Db.FileDesc () FileContentDesc), [MakefileMonad.PutStrLn], Makefile)
parse db absMakefilePath vars = do
  (readFiles, putStrLns, res) <-
    MakefileMonad.runM $
    MakefileParser.parse absMakefilePath vars
  contentDescs <- Map.traverseWithKey (mkFileDesc db) readFiles
  -- This must come after:
  mapM_ (uncurry Meddling.assertFileMTime) $ Map.toList readFiles
  return (contentDescs, putStrLns, res)

cacheInputsMatch ::
  Db ->
  (FilePath, Makefile.Vars, Map FilePath Db.MFileContentDesc) ->
  FilePath -> Vars -> IO Bool
cacheInputsMatch db (oldPath, oldVars, oldFiles) path vars
  | oldPath /= path = return False
  | oldVars /= vars = return False
  | otherwise =
    fmap and $ mapM verifySameContent $ Map.toList oldFiles
  where
    verifySameContent (filePath, oldContentDesc) = do
      mStat <- Dir.getMFileStatus filePath
      newContentDesc <- mkFileDesc db filePath mStat
      return $ oldContentDesc == newContentDesc

data IsHit = Hit | Miss

matchCache ::
  Db -> FilePath -> Vars -> Maybe Db.MakefileParseCache ->
  ((Makefile, [MakefileMonad.PutStrLn]) -> IO r) -> IO r -> IO r
matchCache _ _ _ Nothing _ miss = miss
matchCache db absMakefilePath vars (Just (Db.MakefileParseCache inputs output)) hit miss = do
  isMatch <- cacheInputsMatch db inputs absMakefilePath vars
  if isMatch
    then hit output
    else miss

memoParse :: Db -> FilePath -> Vars -> IO (IsHit, Makefile)
memoParse db absMakefilePath vars = do
  mCache <- Db.readIRef makefileParseCacheIRef
  (isHit, makefile) <-
    matchCache db absMakefilePath vars mCache hit $ do
      (newFiles, putStrLns, makefile) <- parse db absMakefilePath vars
      Db.writeIRef makefileParseCacheIRef $
        Db.MakefileParseCache (absMakefilePath, vars, newFiles) (makefile, putStrLns)
      return (Miss, makefile)
  E.evaluate $ rnf makefile
  return (isHit, makefile)
  where
    hit (makefile, putStrLns) = do
      mapM_ MakefileMonad.runPutStrLn putStrLns
      return (Hit, makefile)
    makefileParseCacheIRef = Db.makefileParseCache db
