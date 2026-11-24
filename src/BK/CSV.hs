{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE LinearTypes #-}
{-|
Module      : CSV
Description : Functions for working with the CSV config file.
Copyright   : (c) Harley Eades, 2026
Maintainer  : harley.eades@gmail.com


-}
module BK.CSV (bookmarkCSVFilePath
              ,readBookmarksCSVFile
              ,header
              ,readCSVFile
              ,writeCSVFile) where

import qualified Data.Unrestricted.Linear as Linear
import qualified System.IO.Resource.Linear as Linear
import qualified Control.Functor.Linear as Linear
import BK.BKMap (BKMap, Bookmark, bookmarks, emptyBKMap, insertBK)
import Data.Text (Text)
import System.Exit (exitFailure)
import System.IO (IOMode(..))
import qualified Data.ByteString as BS
import qualified Data.Csv.Incremental as CsvInc
import qualified BK.Lib as Lib
import Data.Csv (encodeByName, Name)
import qualified Data.Vector as Vec
import System.FilePath ((</>))
import qualified Data.Text as DT
import BK.Config (bkHomeDir)

-- | Get the path to the bookmarks file.
bookmarkCSVFilePath :: IO FilePath
bookmarkCSVFilePath 
    = do wdir <- bkHomeDir
         let bookmarkCSVFile = wdir </> "bookmarks.csv"
         pure bookmarkCSVFile

readBookmarksCSVFile :: IO BKMap
readBookmarksCSVFile 
    = do bookmarkCSVFile <- bookmarkCSVFilePath
         (errs,bkMap) <- readCSVFile bookmarkCSVFile
         if null errs
         then pure bkMap
         else print errs >> exitFailure

readCSVFile 
    :: FilePath 
    -> IO ([Text], BKMap)
readCSVFile csvFilePath = Linear.run $ readCSVFile' 
    where
        readCSVFile' 
            :: Linear.RIO (Linear.Ur ([Text], BKMap))
        readCSVFile' = Linear.do            
            csvFile <- Linear.openFile csvFilePath ReadMode
            (Linear.Ur contents) <- loop ([],emptyBKMap) csvFile (CsvInc.decode CsvInc.HasHeader) 
            Linear.return (Linear.Ur contents)

header :: Vec.Vector Name
header = Vec.fromList 
    ["type",
     "label",
     "target",
     "created-data",
     "last-used"]

writeCSVFile
    :: FilePath
    -> BKMap
    -> IO ()
writeCSVFile csvFilePath bkMap = Linear.run writeCSVFile' 
    where        
        bks = Lib.byteStringToTextUTF8 . 
                Lib.lazyByteStringToByteString $ 
                    encodeByName header $ bookmarks bkMap

        writeCSVFile' :: Linear.RIO (Linear.Ur ())
        writeCSVFile' = Linear.do
            csvFile <- Linear.openFile csvFilePath WriteMode
            csvFile' <- Linear.hPutStr csvFile bks
            Linear.release csvFile'
            Linear.return (Linear.Ur ())

feedCSVFile 
    :: (BS.ByteString -> CsvInc.Parser Bookmark)
    -> Linear.Handle %1
    -> Linear.RIO (Linear.Ur (CsvInc.Parser Bookmark), Linear.Handle)
feedCSVFile parserFam csvFile = Linear.do
    (Linear.Ur isEOF, csvFile') <- Linear.hIsEOF csvFile
    if isEOF
    then Linear.return (Linear.Ur (parserFam BS.empty),csvFile')
    else Linear.do
        (Linear.Ur line,csvFile'') <- Linear.hGetLine csvFile'
        let line' = Lib.textUTF8ToByteString (DT.concat [line,(DT.pack "\n")])
        let parser = parserFam line'
        Linear.return (Linear.Ur parser,csvFile'')

updateAcc :: ([Text], BKMap)
          -> [Either String Bookmark]
          -> ([Text], BKMap)
updateAcc acc = Prelude.foldl upAcc acc
    where
        upAcc (errs,bkMap) (Left errMsg) = (errs <> [DT.pack errMsg],bkMap)
        upAcc (errs,bkMap) (Right b)     = (errs,insertBK b bkMap)

loop :: ([Text], BKMap)
     -> Linear.Handle %1
     -> CsvInc.Parser Bookmark 
     -> Linear.RIO (Linear.Ur ([Text], BKMap))
loop acc csvFile (CsvInc.Fail _ errMsg)   
    = Linear.do 
        Linear.release csvFile 
        Linear.return (Linear.Ur (updateAcc acc [Left errMsg]))

loop acc csvFile (CsvInc.Many rs parserFam) 
    = Linear.do         
        (Linear.Ur parser,csvFile'') <- feedCSVFile parserFam csvFile
        loop (updateAcc acc rs) csvFile'' parser                                       

loop acc csvFile (CsvInc.Done rs) 
    = Linear.do     
        Linear.release csvFile 
        Linear.return (Linear.Ur (updateAcc acc rs))
