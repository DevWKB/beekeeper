{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE DeriveDataTypeable     #-}
{-# LANGUAGE ViewPatterns           #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE DataKinds              #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}
{-# LANGUAGE LambdaCase #-}
module BK.TUI (mainLoop, handleMapOpt) where

--
-- * External Imports:
--
import Data.Text          (Text)
import System.Exit        (exitFailure
                          ,exitWith, exitSuccess, ExitCode)
import Data.Time.Calendar (Day)
import Data.Time          (getCurrentTime
                          ,UTCTime (..))
import System.Process     (CreateProcess (..)
                          ,proc
                          ,createProcess
                          ,waitForProcess)
import System.Environment (lookupEnv
                          ,getEnvironment)
import Control.Monad      (void, when)
import System.FilePath    (takeFileName)

import Options.Applicative  qualified as OptA
import Data.Attoparsec.Text qualified as Atto
import Data.Text            qualified as DT

--
-- * Internal Imports:                                     
-- 
import BK.BKMap  (BKType (..)
                 ,Bookmark (..)
                 ,BKMap
                 ,showBKType
                 ,addBookmark
                 ,bookmark
                 ,findBookmark
                 ,removeBookmark
                 ,maxOffsetBKMap
                 ,recentBookmarks
                 ,showBKMap
                 ,filterBKMap
                 ,isAlias
                 ,isBookmark
                 ,filterLabels
                 ,renameBookmark)

import BK.Lib    qualified as Lib
import Data.Char qualified as DC
import BK.CSV (readBookmarksCSVFile, bookmarkCSVFilePath, readCSVFile, writeCSVFile)
import BK.Config (progVersion, progName)
import BK.Setup (initBK)
import BK.Shell (runCmdInShell)

--
-- * Option parsing
-- 

data MapOption 
    = OptAddBK BKType Text Text -- ^ Option "add" handles both bookmarks and aliases.
    | OptRenameBK Text Text     -- ^ Option "rename" handles renaming a bookmark/alias.
    | OptRunBK Text [Text]      -- ^ Option "run" handles running a bookmark with arguments.
    | OptRemoveBK Text          -- ^ Option "remove" handles removing a bookmark/alias.    
    | OptFindBK Text            -- ^ Option "find" searches for a bookmark.
    | OptList                   -- ^ Option "list" outputs all bookmarks and aliases to the terminal.
    | OptBookmarks              -- ^ Option "bookmarks" outputs all bookmarks to the terminal.    
    | OptAliases                -- ^ Option "aliases" outputs all aliases to the terminal.    
    | OptRecentsBK              -- ^ Option "recents" outputs the recently added bookmarks and aliases to the terminal.
    deriving Show

-- | All available command-line options.
data BKOption
    = MapOpt MapOption          -- ^ Options for manipulating the map.
    | OptInit                   -- ^ Option "init"  initializes bk.
    deriving Show

--
-- ** Attoparsec Parsers
-- 

-- | Parses an assignment of the form @label=target@.
-- Skips over whitespace before and after the @=@.
assignParser :: Atto.Parser (Text,Text)
assignParser = do 
    label <- labelParser
    Atto.skipSpace
    Atto.skip (=='=')
    Atto.skipSpace
    target <- targetParser
    return $ (label,target)

-- | Parses a bookmark label.
-- Labels must start with a letter and then be alpha-numeric with the addition of @_@ and @-@.
labelParser :: Atto.Parser Text
labelParser = do
    startChar <- Atto.take 1      
    if DT.all DC.isAlpha startChar
    then do
        rest <- Atto.takeWhile1 $ DC.isAlphaNum `Lib.orF` (`elem` ['-','_'])             
        return $ DT.append startChar rest
    else fail $ "parse error: bookmark labels must start with a letter."

-- | Parses the target of a bookmark.
-- Currently, there are no conditions on what a target can be, but in the future
-- we will need to modify this to handle variables. 
-- 
-- Reminder: the shell seems to be removing any quotes from the assignment.
targetParser :: Atto.Parser Text
targetParser = Atto.takeText            

-- | Parses the label of a bookmark.
labelArg :: OptA.ReadM Text
labelArg = OptA.eitherReader $ Atto.parseOnly labelParser . DT.pack

-- | Parses an "add" option (`OptAddBK`) from an assignment argument.
optAddBKParser 
    :: BKType -- ^ Type of the bookmark being added
    -> Atto.Parser BKOption
optAddBKParser bkType = do 
    (label,target) <- assignParser
    return $ MapOpt $ OptAddBK bkType label target

--
-- ** Optparse-Applicative Parsers
-- 

-- | Imports the `optAddBKParser` into optparse-applicative as an argument
-- parser.
bkAddBkParser 
    :: BKType -- ^ Type of the bookmark being added
    -> OptA.Parser BKOption
bkAddBkParser bkType = OptA.argument (parser bkType) (OptA.metavar "LABEL=TARGET")
    where
        parser :: BKType -> OptA.ReadM BKOption
        parser bkType = OptA.eitherReader 
                      $ Atto.parseOnly (optAddBKParser bkType) . DT.pack

completeLabel :: String -> IO [String]
completeLabel partial = do
    bkMap <- readBookmarksCSVFile
    return . map DT.unpack $ filterLabels labelMatch bkMap
  where
    labelMatch l = DT.isPrefixOf (DT.toLower . DT.pack $ partial) $ DT.toLower l

-- | Parses the arguments to the run option.
bkRunCmdParser :: OptA.Parser BKOption
bkRunCmdParser  = MapOpt 
               <$> (OptRunBK
                 <$> (OptA.argument labelArg 
                         (OptA.metavar "LABEL" 
                       <> OptA.completer (OptA.mkCompleter completeLabel)))
                 <*> (OptA.many $ OptA.argument OptA.str (OptA.metavar "ARGS")))

-- | Parses the arguments to the @remove@ command.
bkRemoveCmdParser :: OptA.Parser BKOption    
bkRemoveCmdParser  
    = MapOpt 
    <$> OptRemoveBK
    <$> OptA.argument labelArg (OptA.metavar "LABEL" <> OptA.completer (OptA.mkCompleter completeLabel))      

-- | Parses the arguments to the @rename@ command.
bkRenameCmdParser :: OptA.Parser BKOption    
bkRenameCmdParser
    = MapOpt 
   <$> (OptRenameBK
     <$> OptA.argument labelArg 
           (OptA.metavar "LABEL1" 
         <> OptA.completer (OptA.mkCompleter completeLabel))      
     <*> OptA.argument labelArg (OptA.metavar "LABEL2"))

-- | Parses the argument to @find@ command.
bkFindCmdParser :: OptA.Parser BKOption
bkFindCmdParser 
    = MapOpt 
   <$> OptFindBK
   <$> OptA.argument labelArg (OptA.metavar "LABEL")      

-- | Parses the @list@ command.
bkListCmdParser :: OptA.Parser BKOption
bkListCmdParser = pure $ MapOpt OptList

-- | Parses the @bookmarks@ command.
bkListBksCmdParser :: OptA.Parser BKOption
bkListBksCmdParser = pure $ MapOpt OptBookmarks

-- | Parses the @aliases@ command.
bkListAliasesCmdParser :: OptA.Parser BKOption
bkListAliasesCmdParser = pure $ MapOpt OptAliases

-- | Parses the @aliases@ command.
bkRecentsParser :: OptA.Parser BKOption
bkRecentsParser = pure $ MapOpt OptRecentsBK

-- | Parses the @init@ command.
bkInitBkParser :: OptA.Parser BKOption
bkInitBkParser = pure OptInit

-- | Parses the various command-line options.
bkCmdParser :: OptA.Parser BKOption
bkCmdParser = OptA.hsubparser 
 (  OptA.command "init"      (OptA.info bkInitBkParser   
                             (OptA.progDesc "Initialize bk's configuration"))
 <> OptA.command "bookmark"  (OptA.info (bkAddBkParser BKBookmark) 
                             (OptA.progDesc "Add a bookmark"))
 <> OptA.command "alias"     (OptA.info (bkAddBkParser BKAlias)    
                             (OptA.progDesc "Add an alias"))
 <> OptA.command "run"       (OptA.info bkRunCmdParser             
                             (OptA.progDesc "Runs a bookmark or alias"))
 <> OptA.command "rename"    (OptA.info bkRenameCmdParser          
                             (OptA.progDesc "Renames a bookmark or alias"))
 <> OptA.command "remove"    (OptA.info bkRemoveCmdParser          
                             (OptA.progDesc "Removes a bookmark or alias"))
 <> OptA.command "find"      (OptA.info (bkFindCmdParser)          
                             (OptA.progDesc "Searches for a bookmark or alias"))
 <> OptA.command "list"      (OptA.info (bkListCmdParser)          
                             (OptA.progDesc "Lists all bookmarks and aliases"))
 <> OptA.command "bookmarks" (OptA.info (bkListBksCmdParser)       
                             (OptA.progDesc "Lists all bookmarks"))
 <> OptA.command "aliases"   (OptA.info (bkListAliasesCmdParser)   
                             (OptA.progDesc "Lists all aliases"))
 )
 OptA.<|> bkRunCmdParser       -- run is the default when no commands are given.
 OptA.<|> bkRecentsParser      -- No options or arguments, then show recents.

-- | Generates the various additional options and messages using the command
-- parser. This adds the @--help@ and @--version@ options as well as the program
-- description and header for the help message.
bkOpts :: OptA.ParserInfo BKOption
bkOpts 
  = OptA.info 
      (bkCmdParser OptA.<**> OptA.helper 
                   OptA.<**> OptA.simpleVersioner progVersion)
      (OptA.fullDesc 
             <> OptA.progDesc progName 
             <> OptA.header "BeeKeeper remembers so you don't have to!")

--
-- * Option Handlers
-- 

-- | Handles initialization.
handleOptInit :: IO ()
handleOptInit = void initBK

-- | Handles any command that manipulates the map.
handleMapOpt 
    :: MapOption -- ^ Option to handle
    -> BKMap     
    -> IO (Maybe BKMap)
handleMapOpt OptRecentsBK        bkMap = handleRecentsbk bkMap
handleMapOpt OptList             bkMap = handleListBookmarks Nothing bkMap
handleMapOpt OptBookmarks        bkMap = handleListBookmarks (Just BKBookmark) bkMap
handleMapOpt OptAliases          bkMap = handleListBookmarks (Just BKAlias) bkMap
handleMapOpt (OptAddBK ty l t)   bkMap = handleAddbk ty l t bkMap
handleMapOpt (OptFindBK l)       bkMap = handleFindbk l bkMap
handleMapOpt (OptRunBK l args)   bkMap = handleRunbk l args bkMap 
                                      >> pure Nothing
handleMapOpt (OptRemoveBK l)     bkMap = handleRemovebk l bkMap
handleMapOpt (OptRenameBK l1 l2) bkMap = handleRenamebk l1 l2 bkMap

-- | Handler for the @add@ option.
handleAddbk 
    :: BKType -- ^ Type of the bookmark being added
    -> Text   -- ^ Label of the bookmark being added
    -> Text   -- ^ Target of the bookmark being added
    -> BKMap  -- ^ Contents of the CSV file
    -> IO (Maybe BKMap)
handleAddbk ty l t csvContents = do
    createdDay <- today
    Just <$> handleAddbk' ty l t createdDay csvContents
    where
        today :: IO Day
        today = do
            currentUTCTime <- getCurrentTime
            return . utctDay $ currentUTCTime

        handleAddbk' :: BKType -> Text -> Text -> Day -> BKMap -> IO BKMap
        handleAddbk' typebk labelbk targetbk createdbk csvContents
            = either
                (\errMsg -> Lib.putStrLnStdErr ("error: "<>errMsg) >> return csvContents)
                (\b -> do homedir <- Lib.getHomeDirectory
                          either 
                              (\errMsg -> do Lib.putStrLnStdErr $ "error: " <> errMsg
                                             exitFailure)
                              (\updatedMap -> 
                                  do putStrLn $ "created " <> DT.unpack (showBKType typebk)  <> " \"" <> (DT.unpack labelbk) <> "\""
                                     return updatedMap)
                              $ addBookmark b homedir csvContents)
              $ bookmark typebk labelbk targetbk createdbk createdbk 

-- | Handler for the @find@ option.
handleFindbk 
    :: Text  -- ^ Label of the bookmark to search for
    -> BKMap -- ^ Contents of the CSV file
    -> IO (Maybe BKMap)
handleFindbk labelbk csvContents = do
    maybe (Lib.putStrLnStdErr $ "bookmark not found " <> DT.show labelbk)
          print
        $ findBookmark labelbk csvContents
    return Nothing

-- | Handler for the @remove@ option.
handleRemovebk 
    :: Text  -- ^ Label of the bookmark to remove
    -> BKMap -- ^ Contents of the CSV file
    -> IO (Maybe BKMap)
handleRemovebk labelbk csvContents = do
        putStrLn $ "removed bookmark " <> show (DT.unpack labelbk)
        return . Just $ removeBookmark labelbk csvContents

-- | Handler for the @rename@ option.
handleRenamebk 
    :: Text  -- ^ Label of the bookmark to rename
    -> Text  -- ^ new label
    -> BKMap -- ^ Contents of the CSV file
    -> IO (Maybe BKMap)
handleRenamebk old_labelbk new_labelbk bkMap = do
        let mNewMap = renameBookmark old_labelbk new_labelbk bkMap
        case mNewMap of
            Just newMap -> do putStrLn . DT.unpack $ "renamed " <> Lib.dq_text old_labelbk <> " to " <> Lib.dq_text new_labelbk
                              pure . Just $ newMap
            Nothing -> do Lib.putStrLnStdErr $ "error: bookmark " <> Lib.dq_text old_labelbk <> " couldn't be found."
                          pure Nothing        

-- | Handler for the @run@ option.
handleRunbk 
    :: Text   -- ^ Label of the bookmark to run
    -> [Text] -- ^ List of arguments to pass to the target
    -> BKMap  -- ^ Contents of the CSV file
    -> IO ()
handleRunbk labelbk inArgs csvContents = do
    case findBookmark labelbk csvContents of
        Nothing -> Lib.putStrLnStdErr $ "bookmark not found " <> DT.show labelbk
        Just b -> 
            case bkType b of
                BKBookmark -> putStrLn . DT.unpack . bkTarget $ b
                BKAlias
                    | DT.null . DT.strip $ bkTarget b ->
                        Lib.putStrLnStdErr 
                            $ "error: target is empty for label \"" 
                            <> (bkLabel b) 
                            <> "\""
                    | otherwise -> runCmdInShell (bkTarget b) inArgs 
                                >>= exitWith

-- | Handler for the @recents@ option.
handleRecentsbk 
    :: BKMap            -- ^ Contents of the CSV file
    -> IO (Maybe BKMap)
handleRecentsbk csvContents = 
        do today <- getCurrentTime
           let maxLabelOffset = maxOffsetBKMap csvContents
           let (recAliases,recBks) = recentBookmarks (utctDay today) csvContents
           --TODO: Need to pull this out into a function def:
           putStrLn . DT.unpack  $ showBKMap maxLabelOffset recAliases
           putStrLn . DT.unpack  $ showBKMap maxLabelOffset recBks
           return Nothing

-- | Handler for the @list@ option.
-- If the input is @Nothing@ then list all of the bookmarks and aliases, but if
-- it's @Just bkType@ then filter the list based on the value of @bkType@.
handleListBookmarks 
    :: Maybe BKType -- ^ List filter
    -> BKMap        -- ^ Contents of the CSV file
    -> IO (Maybe BKMap)
handleListBookmarks mbkType csvContents = 
    do let _map = filterBKMap (pred mbkType) csvContents
       let maxLabelOffset = maxOffsetBKMap _map
       putStrLn . DT.unpack  $ showBKMap maxLabelOffset _map
       return Nothing
    where
        pred :: Maybe BKType -> Bookmark -> Bool
        pred Nothing _ = True
        pred (Just BKAlias) bk    = isAlias bk
        pred (Just BKBookmark) bk = isBookmark bk

_handler :: Bool -> (BKMap  -> IO BKMap) -> IO ()
_handler writeMode action = 
    do bookmarkCSVFile <- bookmarkCSVFilePath
       (errs,csvContents) <- readCSVFile bookmarkCSVFile       
       if null errs
       then do csvContents' <- action csvContents                                       
               when writeMode $ 
                 writeCSVFile bookmarkCSVFile csvContents'
               exitSuccess
       else print errs >> exitFailure

mainHandler :: MapOption -> IO ()
mainHandler opt
    = do bookmarkCSVFile <- bookmarkCSVFilePath
         bookmarkCSVFileExists <- Lib.doesFileExist bookmarkCSVFile
         when bookmarkCSVFileExists $ do 
           (errs,csvContents) <- readCSVFile bookmarkCSVFile       
           if null errs
           then do
             updatedMapM <- handleMapOpt opt csvContents
             maybe (return ())
                   (writeCSVFile bookmarkCSVFile)
                   updatedMapM
             exitSuccess
            else print errs >> exitFailure
         Lib.exitFailureWithMsg $ "bk uninitialized, run `bk init`."

-- | The main loop. 
-- This is called by the `Main` module.
mainLoop ::  IO ()
mainLoop = OptA.execParser bkOpts >>= \case
    OptInit    -> handleOptInit
    MapOpt opt -> mainHandler opt    