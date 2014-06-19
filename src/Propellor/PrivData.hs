{-# LANGUAGE PackageImports #-}

module Propellor.PrivData where

import qualified Data.Map as M
import Control.Applicative
import System.FilePath
import System.IO
import System.Directory
import Data.Maybe
import Data.List
import Control.Monad
import Control.Monad.IfElse
import "mtl" Control.Monad.Reader

import Propellor.Types
import Propellor.Message
import Utility.Monad
import Utility.PartialPrelude
import Utility.Exception
import Utility.Process
import Utility.Tmp
import Utility.SafeCommand
import Utility.Misc
import Utility.FileMode
import Utility.Env

-- | When the specified PrivDataField is available on the host Propellor
-- is provisioning, it provies the data to the action. Otherwise, it prints
-- a message to help the user make the necessary private data available.
withPrivData :: PrivDataField -> (String -> Propellor Result) -> Propellor Result
withPrivData field a = maybe missing a =<< liftIO (getPrivData field)
  where
	missing = do
		host <- asks hostName
		let host' = if ".docker" `isSuffixOf` host
			then "$parent_host"
			else host
		liftIO $ do
			warningMessage $ "Missing privdata " ++ show field
			putStrLn $ "Fix this by running: propellor --set "++host'++" '" ++ show field ++ "'"
			return FailedChange

getPrivData :: PrivDataField -> IO (Maybe String)
getPrivData field = do
	m <- catchDefaultIO Nothing $ readish <$> readFile privDataLocal
	return $ maybe Nothing (M.lookup field) m

setPrivData :: HostName -> PrivDataField -> IO ()
setPrivData host field = do
	putStrLn "Enter private data on stdin; ctrl-D when done:"
	setPrivDataTo host field =<< hGetContentsStrict stdin

dumpPrivData :: HostName -> PrivDataField -> IO ()
dumpPrivData host field =
	maybe (error "Requested privdata is not set.") putStrLn
		=<< getPrivDataFor host field

setPrivDataTo :: HostName -> PrivDataField -> String -> IO ()
setPrivDataTo host field value = do
	makePrivDataDir
	let f = privDataFile host
	m <- decryptPrivData host
	let m' = M.insert field (chomp value) m
	gpgEncrypt f (show m')
	putStrLn "Private data set."
	void $ boolSystem "git" [Param "add", File f]
  where
	chomp s
		| end s == "\n" = chomp (beginning s)
		| otherwise = s

getPrivDataFor :: HostName -> PrivDataField -> IO (Maybe String)
getPrivDataFor host field = M.lookup field <$> decryptPrivData host

editPrivData :: HostName -> PrivDataField -> IO ()
editPrivData host field = do
	v <- getPrivDataFor host field
	v' <- withTmpFile "propellorXXXX" $ \f _h -> do
		maybe noop (writeFileProtected f) v
		editor <- getEnvDefault "EDITOR" "vi"
		unlessM (boolSystem editor [File f]) $
			error "Editor failed; aborting."
		readFile f
	setPrivDataTo host field v'

decryptPrivData :: HostName -> IO (M.Map PrivDataField String)
decryptPrivData host = fromMaybe M.empty . readish
	<$> gpgDecrypt (privDataFile host)

makePrivDataDir :: IO ()
makePrivDataDir = createDirectoryIfMissing False privDataDir

privDataDir :: FilePath
privDataDir = "privdata"

privDataFile :: HostName -> FilePath
privDataFile host = privDataDir </> host ++ ".gpg"

privDataLocal :: FilePath
privDataLocal = privDataDir </> "local"

gpgDecrypt :: FilePath -> IO String
gpgDecrypt f = ifM (doesFileExist f)
	( readProcess "gpg" ["--decrypt", f]
	, return ""
	)

gpgEncrypt :: FilePath -> String -> IO ()
gpgEncrypt f s = do
	encrypted <- writeReadProcessEnv "gpg"
		[ "--default-recipient-self"
		, "--armor"
		, "--encrypt"
		]
		Nothing
		(Just $ flip hPutStr s)
		Nothing
	viaTmp writeFile f encrypted
