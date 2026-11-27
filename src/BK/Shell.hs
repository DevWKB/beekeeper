{-|
Module      : Shell
Description : Library for interacting with the users shell.
Copyright   : (c) Harley Eades, 2026
Maintainer  : harley.eades@gmail.com

-}
module BK.Shell (Shell(..)
                ,userShell
                ,runCmdInShell
                ,detectShell
                ,readEnvVar
                ,envOr
                ,rcFilePath
                ,lookupProfile
                ,isGitInstalled) where

import Data.Text          (Text)
import Data.Text          qualified as DT
import GHC.IO.Exception   (ExitCode (..))
import System.Process     (delegate_ctlc
                          ,CreateProcess (..)
                          ,proc
                          ,createProcess
                          ,waitForProcess)
import System.FilePath    (takeFileName, (</>))
import System.Environment (lookupEnv
                          ,getEnvironment)
import BK.Config (Profile, profileEnvVar, parseProfile)
import System.Info (os)
import Data.Functor.Identity (Identity(..))

-- | * Shells

-- | Shells that @bk@ can install completions for.
data Shell = Bash
           | Zsh
           | Fish
  deriving (Eq, Show)

-- | Determines the user's shell from the @SHELL@ environment variable.
detectShell :: IO (Maybe Shell)
detectShell = parseShell . maybe "" takeFileName <$> lookupEnv "SHELL"
  where
    parseShell :: String -> Maybe Shell
    parseShell "bash" = Just Bash
    parseShell "zsh"  = Just Zsh
    parseShell "fish" = Just Fish
    parseShell _      = Nothing

-- | Runs a command in the users shell. 
runCmdInShell 
    :: Text         -- ^ Command
    -> [Text]       -- ^ Command's arguments
    -> IO ExitCode
runCmdInShell cmd inArgs
    = do sh     <- userShell
         curEnv <- getEnvironment
         -- The target is run as shell source; the extra
         -- arguments are passed as positional parameters so
         -- that their quoting is preserved.
         --
         -- POSIX-style shells: @"$@"@, with @$0@ set to "bk".
         -- fish: @$argv@, which holds every argument after the
         -- script (there is no @$0@ slot, and fish rejects
         -- @$@@). Fish doesn't word-split or glob variable
         -- values, so @$argv@ needs no quoting.
         let isFish = takeFileName sh == "fish"
             (argRef, zeroArg)
                 | isFish    = (" $argv",  [])
                 | otherwise = (" \"$@\"", ["bk"])
             script = DT.unpack cmd <> argRef             
             -- macOS Terminal's session save/restore would print
             -- to stdout and share the parent tab's history file.
             childEnv = ("SHELL_SESSIONS_DISABLE","1")
                         : filter ((/= "SHELL_SESSIONS_DISABLE") . fst) curEnv
             args = (["-i", "-c", script] 
               <> zeroArg 
               <> map DT.unpack inArgs)
             cp = (proc sh args)
                        {delegate_ctlc = True
                        ,env           = Just childEnv }
         (_,_,_,ph) <- createProcess cp
         waitForProcess ph 

-- | The user's shell, taken from @$SHELL@, falling back to @/bin/sh@.
userShell :: IO FilePath
userShell = do
    mShell <- lookupEnv "SHELL"
    pure $ case mShell of
        Just sh | not (null sh) -> sh
        _                       -> "/bin/sh"

-- | Read an environment variable from the users shell environment.
readEnvVar :: [Char] -> IO (Maybe String)
readEnvVar envVar = envOr envVar Nothing

-- | Looks up an environment variable, falling back to a default when it is
-- unset or empty.
envOr :: Applicative f => String -> f String -> IO (f String)
envOr var def = do
  valM <- lookupEnv var
  pure $ case valM of
    Just val | not (null val) -> pure val
    _                         -> def

-- | The profile set in the environment, if @BK_PROFILE@ is set and non-empty.
lookupProfile :: IO (Maybe Profile)
lookupProfile = do val <- readEnvVar profileEnvVar 
                   pure . fmap parseProfile $ val

-- | The rc file to update, if the shell needs one.
-- On macOS, Terminal starts bash as a login shell, which reads
-- @~/.bash_profile@ instead of @~/.bashrc@.
rcFilePath :: FilePath -> Shell -> IO (Maybe FilePath)
rcFilePath homedir Bash
  | os == "darwin" = pure . Just $ homedir </> ".bash_profile"
  | otherwise      = pure . Just $ homedir </> ".bashrc"
rcFilePath homedir Zsh = do
  Identity zdotdir <- envOr "ZDOTDIR" $ pure homedir
  pure . Just $ zdotdir </> ".zshrc"
rcFilePath _ Fish = pure Nothing

-- | Determine if Git is installed in the users shell.
isGitInstalled :: IO Bool
isGitInstalled 
    = do ec <- runCmdInShell "which git >/dev/null 2&>1" []
         pure $ case ec of 
                    ExitSuccess -> True
                    _ -> False

-- | Setup a git repository in the given directory.
setupGitRepo :: FilePath -> IO ()
setupGitRepo = undefined