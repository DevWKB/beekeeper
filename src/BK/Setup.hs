module BK.Setup
    (initBK    
    ,initializeWorkDir) where

-- | * External Imports

import Data.Maybe                         (listToMaybe
                                          ,mapMaybe)
import Data.Text                          (Text)
import System.IO                          (hFlush
                                          ,hIsEOF
                                          ,stdin
                                          ,stdout)
import System.FilePath                    ((</>)
                                          ,takeDirectory
                                          )
import Options.Applicative.BashCompletion (bashCompletionScript
                                          ,zshCompletionScript
                                          ,fishCompletionScript)

import Data.Text    qualified as DT
import Data.Text.IO qualified as DT

-- | * Internal Imports

import BK.Lib   qualified as Lib
import BK.BKMap (emptyBKMap)
import Control.Monad (when)
import BK.Config (bkHomeDir, progName, Profile (..), parseProfile, validProfileName, profileEnvVar, renderProfile)
import BK.CSV (bookmarkCSVFilePath, writeCSVFile)
import BK.Shell (Shell (..), detectShell, rcFilePath, lookupProfile, envOr, isGitInstalled)
import Data.Functor.Identity (Identity (Identity))
import BK.Lib (exitFailureWithMsg)

-- | * Initialization

-- | Sets up @bk@:
--
-- 0. Detects if Git is installed and creates a Git repository in @~/.bk@.
-- 1. Creates @~/.bk/bookmarks.csv@ if it doesn't already exist.
-- 2. Detects the user's shell and installs the completion script where that
--    shell will load it. When the shell's rc file needs updating, the user is
--    asked first; if they decline, the lines to add manually are printed.
-- 3. Determines the user's profile (see 'setupProfile') and returns it.
--
-- Safe to run more than once: the completion script is regenerated, and the
-- rc file is only modified (and the user only asked) the first time.
initBK :: IO Profile
initBK = do
  gitIsInstalled <- isGitInstalled
  if gitIsInstalled 
  then do
    initializeWorkDir
    sh_ <- detectShell
    maybe unsupportedShell setupShell sh_
  else exitFailureWithMsg "error: Git not found, but is required for setup."
  where
    unsupportedShell = Lib.exitFailureWithMsg $
         "error: unable to determine your shell from $SHELL.\n"
      <> "Supported shells: bash, zsh, and fish."

initializeWorkDir :: IO ()
initializeWorkDir = do
    wdir <- bkHomeDir
    bookmarkCSVFile <- bookmarkCSVFilePath
    Lib.createDirectoryIfMissing False wdir
    bookmarkCSVFileExists <- Lib.doesFileExist bookmarkCSVFile
    when (not bookmarkCSVFileExists) $
      writeCSVFile bookmarkCSVFile emptyBKMap

-- | Writes the completion script for the given shell and, for bash and zsh,
-- adds blocks to the shell's rc file that load it and export @BK_PROFILE@.
setupShell :: Shell -> IO Profile
setupShell sh = do
  homedir    <- Lib.getHomeDirectory
  scriptPath <- completionScriptPath homedir sh
  Lib.createDirectoryIfMissing True (takeDirectory scriptPath)
  writeFile scriptPath (completionScript sh)
  Lib.putStrLnStdOut $ "Installed "
                    <> DT.pack (show sh)
                    <> " completions to "
                    <> DT.pack scriptPath
  rcFileM <- rcFilePath homedir sh
  maybe (pure ()) (setupRcFile (completionsBlock sh)) rcFileM
  profile <- setupProfile sh rcFileM
  Lib.putStrLnStdOut "Restart your shell to enable completions."
  pure profile

-- | Determines the user's profile.
--
-- If @BK_PROFILE@ is already set in the environment, its parsed value is
-- returned and nothing else is done. Otherwise, if an earlier run already
-- added the export to the rc file (and the shell hasn't been restarted since),
-- the profile is read back from there. Failing both, the user is asked for a
-- profile name and the export is added to the rc file, with confirmation.
-- Fish has no rc file to update, so the command to run is printed instead.
setupProfile :: Shell -> Maybe FilePath -> IO Profile
setupProfile sh rcFileM = lookupProfile >>= maybe fromRcFile pure
  where
    fromRcFile = case rcFileM of
      Nothing     -> do
        profile <- askProfile
        Lib.putStrLnStdOut $
             "To set your bk profile, run:\n\n"
          <> DT.unlines (rcBlockLines (profileBlock sh profile))
        pure profile
      Just rcFile -> do
        existing <- rcProfile rcFile
        case existing of
          Just profile -> do
            Lib.putStrLnStdOut $
              "BK_PROFILE export already present in " <> DT.pack rcFile
            pure profile
          Nothing      -> do
            profile <- askProfile
            setupRcFile (profileBlock sh profile) rcFile
            pure profile

-- | Asks the user for a profile name. An empty answer or end of input selects
-- the default profile. Re-prompts on an invalid name.
askProfile :: IO Profile
askProfile = loop
  where
    loop = do
      DT.putStr "Profile name [default]: "
      hFlush stdout
      eof <- hIsEOF stdin
      if eof
      then Lib.putStrLnStdOut "" >> pure DefaultProfile
      else do
        name <- DT.unpack . DT.strip <$> DT.getLine
        case name of
          _ | null name             -> pure DefaultProfile
            | validProfileName name -> pure (parseProfile name)
            | otherwise             -> do
                Lib.putStrLnStdOut
                  "Profile names may only contain letters, digits, '-' and '_'."
                loop

-- | The profile exported by the @bk@ profile block in the rc file, if the
-- block is present. A block whose export line is missing or was edited beyond
-- recognition is treated as the default profile.
rcProfile :: FilePath -> IO (Maybe Profile)
rcProfile rcFile = do
  present <- rcBlockPresent profileTag rcFile
  if not present
  then pure Nothing
  else do
    ls <- rcBlockContents profileTag <$> Lib.readFile rcFile
    pure . Just
         . maybe DefaultProfile parseExport
         . listToMaybe
         $ mapMaybe (DT.stripPrefix exportPrefix) ls
  where
    exportPrefix = "export " <> DT.pack profileEnvVar <> "="
    parseExport  = parseProfile . DT.unpack . DT.dropAround (== '"')

-- | Asks a yes/no question on stdout. An empty answer means yes; end of input
-- means no. Re-prompts on anything else.
confirm :: Text -> IO Bool
confirm question = loop
  where
    loop = do
      DT.putStr $ question <> " [Y/n] "
      hFlush stdout
      eof <- hIsEOF stdin
      if eof
      then Lib.putStrLnStdOut "" >> pure False
      else do
        answer <- DT.toLower . DT.strip <$> DT.getLine
        case answer of
          ""    -> pure True
          "y"   -> pure True
          "yes" -> pure True
          "n"   -> pure False
          "no"  -> pure False
          _     -> loop

-- | The completion script generated by optparse-applicative.
completionScript :: Shell -> String
completionScript Bash = bashCompletionScript progName progName
completionScript Zsh  = zshCompletionScript  progName progName
completionScript Fish = fishCompletionScript progName progName

-- | Where the completion script is written.
-- Bash and zsh scripts live in @~/.bk/completions@ and are loaded by the rc
-- file; fish autoloads anything in its user completions directory.
completionScriptPath :: FilePath -> Shell -> IO FilePath
completionScriptPath homedir Bash
  = pure $ bkCompletionsDir homedir </> "bk.bash"
completionScriptPath homedir Zsh
  = pure $ bkCompletionsDir homedir </> "_bk"
completionScriptPath homedir Fish
  = do Identity configDir <- envOr "XDG_CONFIG_HOME" 
                           $ pure (homedir </> ".config")
       pure $ configDir </> "fish" </> "completions" </> "bk.fish"

bkCompletionsDir :: FilePath -> FilePath
bkCompletionsDir homedir = homedir </> ".bk" </> "completions"

-- | * Rc File Blocks

-- | A block of lines @bk@ manages in a shell's rc file. Each block is wrapped
-- in markers carrying its tag, so it can be detected on later runs.
data RcBlock = RcBlock
  { rcBlockTag     :: Text   -- ^ Marker tag, as in @# bk \<tag\> start@.
  , rcBlockDesc    :: Text   -- ^ What the block is, for messages.
  , rcBlockPurpose :: Text   -- ^ What the block is for, for messages.
  , rcBlockLines   :: [Text] -- ^ The lines themselves.
  }

-- | Lines added to the rc file to load the completion script.
completionsBlock :: Shell -> RcBlock
completionsBlock sh = RcBlock
  { rcBlockTag     = "completions"
  , rcBlockDesc    = "completion setup"
  , rcBlockPurpose = "enable completions"
  , rcBlockLines   = completionLines sh
  }
  where
    completionLines Bash =
      [ "[ -f \"$HOME/.bk/completions/bk.bash\" ] && source \"$HOME/.bk/completions/bk.bash\"" ]
    completionLines Zsh =
      [ "fpath=(\"$HOME/.bk/completions\" $fpath)"
        -- Run compinit only if the user's config hasn't already.
      , "(( $+functions[compdef] )) || { autoload -Uz compinit && compinit }"
        -- Register explicitly in case compinit ran before fpath was updated.
      , "autoload -Uz _bk && compdef _bk bk"
      ]
    completionLines Fish = []

profileTag :: Text
profileTag = "profile"

-- | Line exporting @BK_PROFILE@ into the user's shell. For fish, which has no
-- rc file here, this is a universal variable the user sets once.
profileBlock :: Shell -> Profile -> RcBlock
profileBlock sh profile = RcBlock
  { rcBlockTag     = profileTag
  , rcBlockDesc    = DT.pack profileEnvVar <> " export"
  , rcBlockPurpose = "set your bk profile"
  , rcBlockLines   = [profileLine sh]
  }
  where
    var = DT.pack profileEnvVar
    val = renderProfile profile
    profileLine Fish = "set -Ux " <> var <> " " <> val
    profileLine _    = "export " <> var <> "=\"" <> val <> "\""

-- | Adds the block to the shell's rc file after asking the user for
-- confirmation. If they decline, the lines are printed so they can add them
-- manually. Does nothing if the block is already present.
setupRcFile :: RcBlock -> FilePath -> IO ()
setupRcFile block rcFile = do
  present <- rcBlockPresent (rcBlockTag block) rcFile
  if present
  then Lib.putStrLnStdOut $ capitalize desc <> " already present in " <> rcFileT
  else do
    ok <- confirm $ "Add " <> desc <> " to " <> rcFileT <> "?"
    if ok
    then do appendRcBlock rcFile block
            Lib.putStrLnStdOut $ "Added " <> desc <> " to " <> rcFileT
    else Lib.putStrLnStdOut $
              "Left " <> rcFileT <> " unchanged. To " <> rcBlockPurpose block
           <> ", add the following lines to it:\n\n"
           <> rcBlockText block
  where
    rcFileT      = DT.pack rcFile
    desc         = rcBlockDesc block
    capitalize t = DT.toUpper (DT.take 1 t) <> DT.drop 1 t

rcBlockStart, rcBlockEnd :: Text -> Text
rcBlockStart tag = "# bk " <> tag <> " start"
rcBlockEnd   tag = "# bk " <> tag <> " end"

-- | The block's lines wrapped in its markers.
rcBlockText :: RcBlock -> Text
rcBlockText block = DT.unlines $
  [rcBlockStart tag] <> rcBlockLines block <> [rcBlockEnd tag]
  where
    tag = rcBlockTag block

-- | Whether the rc file already contains the block with the given tag.
rcBlockPresent :: Text -> FilePath -> IO Bool
rcBlockPresent tag rcFile = do
  exists <- Lib.doesFileExist rcFile
  if exists
  then DT.isInfixOf (rcBlockStart tag) <$> Lib.readFile rcFile
  else pure False

-- | The (stripped) lines between the markers of the block with the given tag.
rcBlockContents :: Text -> Text -> [Text]
rcBlockContents tag
  = takeWhile (/= rcBlockEnd tag)
  . drop 1
  . dropWhile (/= rcBlockStart tag)
  . map DT.strip
  . DT.lines

-- | Appends the block, wrapped in its markers, to the rc file.
-- Creates the rc file if it doesn't exist.
appendRcBlock :: FilePath -> RcBlock -> IO ()
appendRcBlock rcFile block = DT.appendFile rcFile $ "\n" <> rcBlockText block

