{-|
Module      : Config
Description : Program and System Configuration Settings
Copyright   : (c) Harley Eades, 2026
Maintainer  : harley.eades@gmail.com

-}
module BK.Config (progName, progVersion, bkHomeDir, validProfileName, renderProfile, Profile(..), profileEnvVar, parseProfile) where
import qualified BK.Lib as Lib
import System.FilePath ((</>))
import Data.Text (Text)
import qualified Data.Text as DT
import Data.Char (isAlphaNum)

-- | Name of the executable.
-- Also used as the program path in the completion scripts so that they resolve
-- @bk@ through @PATH@ rather than a fixed install location.
progName :: String
progName = "bk"

progVersion :: String
progVersion = "v0.3"

-- | The location we store all of BK's configuration files.
bkHomeDir :: IO FilePath
bkHomeDir 
    = do homeDir <- Lib.getHomeDirectory
         pure $ homeDir </> ".bk"

-- | * Profiles

-- | The @bk@ profile in use, taken from the @BK_PROFILE@ environment
-- variable. The value @default@ selects 'DefaultProfile'; anything else names
-- a custom profile.
data Profile = DefaultProfile
             | CustomProfile String
  deriving (Eq, Show)

-- | The environment variable holding the user's profile.
profileEnvVar :: String
profileEnvVar = "BK_PROFILE"

-- | Parses a @BK_PROFILE@ value.
parseProfile :: String -> Profile
parseProfile "default" = DefaultProfile
parseProfile name      = CustomProfile name

-- | The @BK_PROFILE@ value for a profile; inverse of 'parseProfile'.
renderProfile :: Profile -> Text
renderProfile DefaultProfile       = "default"
renderProfile (CustomProfile name) = DT.pack name

-- | Profile names are restricted so they can be written into an rc file
-- without quoting concerns.
validProfileName :: String -> Bool
validProfileName name = not (null name) && all valid name
  where
    valid c = isAlphaNum c || c == '-' || c == '_'
