{-|
Module      : Config
Description : Program and System Configuration Settings
Copyright   : (c) Harley Eades, 2026
Maintainer  : harley.eades@gmail.com


-}
module BK.Config (progName, progVersion, bkHomeDir) where
import qualified BK.Lib as Lib
import System.FilePath ((</>))


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
