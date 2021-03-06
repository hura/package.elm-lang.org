{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Routes where

import Control.Applicative
import Control.Monad.Error
import qualified Data.Binary as Binary
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import Snap.Core
import Snap.Util.FileServe
import Snap.Util.FileUploads
import System.Directory
import System.FilePath

import qualified Elm.Package.Description as Desc
import qualified Elm.Package.Name as N
import qualified Elm.Package.Paths as Path
import qualified Elm.Package.Version as V
import qualified GitHub
import qualified NativeWhitelist
import qualified PackageSummary


catalog :: Snap ()
catalog =
    ifTop (serveFile "public/Catalog.html")
    <|> route [ (":name/:version", serveLibrary) ]


serveLibrary :: Snap ()
serveLibrary =
  do  request <- getRequest
      redirectIfLatest request
      let directory = "public" ++ BSC.unpack (rqContextPath request)
      when (List.isInfixOf ".." directory) pass
      exists <- liftIO $ doesDirectoryExist directory
      when (not exists) pass
      ifTop (serveFile (directory </> "index.html")) <|> serveModule request


serveModule :: Request -> Snap ()
serveModule request =
  do  let path = BSC.unpack $ BS.concat
                 [ "public", rqContextPath request, rqPathInfo request, ".html" ]
      when (List.isInfixOf ".." path) pass
      exists <- liftIO $ doesFileExist path
      when (not exists) pass
      serveFile path


redirectIfLatest :: Request -> Snap ()
redirectIfLatest request =
    case (,) <$> rqParam "name" request <*> rqParam "version" request of
      Just ([name], ["latest"]) ->
          let namePath = "catalog" </> BSC.unpack name in
          do rawVersions <- liftIO (getDirectoryContents ("public" </> namePath))
             case Maybe.catMaybes (map V.fromString rawVersions) of
               vs@(_:_) -> redirect path'
                   where
                     path' = BSC.concat [ "/", BSC.pack project, "/", rqPathInfo request ]
                     project = namePath </> V.toString version
                     version = last (List.sort vs)

               _ -> return ()

      _ -> return ()


-- DIRECTORIES

allPackages :: FilePath
allPackages =
    "packages"


packageRoot :: N.Name -> V.Version -> FilePath
packageRoot name version =
    allPackages </> N.toFilePath name </> V.toString version


documentationPath :: FilePath
documentationPath =
    "documentation.json"


-- REGISTER MODULES

register :: Snap ()
register =
  do  name <- getParameter "name" N.fromString
      version <- getParameter "version" V.fromString

      verifyVersion name version

      let directory = packageRoot name version
      liftIO (createDirectoryIfMissing True directory)
      uploadFiles directory
      description <- Desc.read (directory </> Path.description)
      verifyWhitelist (Desc.name description)
      liftIO (PackageSummary.add description)


verifyVersion :: N.Name -> V.Version -> Snap ()
verifyVersion name version =
  do  maybeVersions <- liftIO (PackageSummary.readVersionsOf name)
      case maybeVersions of
        Just localVersions
          | version `elem` localVersions ->
                httpStringError 400
                    ("Version " ++ V.toString version ++ " has already been registered.")

        _ -> return ()

      publicVersions <- GitHub.getVersionTags name
      case version `elem` publicVersions of
        True -> return ()
        False ->
           httpStringError 400
              ("The tag " ++ V.toString version ++ " has not been pushed to GitHub.")


verifyWhitelist :: N.Name -> Snap ()
verifyWhitelist name =
  do  whitelist <- liftIO NativeWhitelist.read
      case True of -- name `elem` whitelist of
        True -> return ()
        False -> httpStringError 400 (whitelistError name)


whitelistError :: N.Name -> String
whitelistError name =
    "You are trying to publish a project that has native-modules. For now,\n\
    \any modules that use Native code must go through a formal review process to\n\
    \make sure the exposed API is pure and the Native code is absolutely\n\
    \necessary. Please open an issue with the title:\n\n"
    ++ "    \"Native review for " ++ N.toString name ++ "\"\n\n"
    ++ "to begin the review process at <https://github.com/elm-lang/elm-get/issues>"


-- UPLOADING FILES

uploadFiles :: FilePath -> Snap ()
uploadFiles directory =
    handleFileUploads "/tmp" defaultUploadPolicy perPartPolicy (handleParts directory)
  where
    perPartPolicy info =
        if okayPart "documentation" info || okayPart "description" info
          then allowWithMaximumSize $ 2^(19::Int)
          else disallow


okayPart :: BSC.ByteString -> PartInfo -> Bool
okayPart field part =
    partFieldName part == field
    && partContentType part == "application/json"


handleParts :: FilePath -> [(PartInfo, Either PolicyViolationException FilePath)] -> Snap ()
handleParts dir parts =
    case parts of
      [(info1, Right temp1), (info2, Right temp2)]
        | okayPart "documentation" info1 && okayPart "description" info2 ->
            liftIO $
            do  BS.readFile temp1 >>= BS.writeFile (dir </> documentationPath)
                BS.readFile temp2 >>= BS.writeFile (dir </> Path.description)

        | okayPart "documentation" info2 && okayPart "description" info1 ->
            liftIO $
            do  BS.readFile temp2 >>= BS.writeFile (dir </> documentationPath)
                BS.readFile temp1 >>= BS.writeFile (dir </> Path.description)

      _ ->
        do  mapM (writePartError . snd) parts
            httpStringError 404 $
                "Files " ++ documentationPath ++ " and " ++ Path.description ++ " were not uploaded."


writePartError :: Either PolicyViolationException FilePath -> Snap ()
writePartError part =
    case part of
      Right _ ->
          return ()

      Left exception ->
          writeText (policyViolationExceptionReason exception)


-- FETCH ALL AVAILABLE VERSIONS

versions :: Snap ()
versions =
  do  name <- getParameter "name" N.fromString
      versions <- liftIO (PackageSummary.readVersionsOf name)
      writeLBS (Binary.encode versions)


-- FETCH DOCUMENTATION

documentation :: Snap ()
documentation =
  do  name <- getParameter "name" N.fromString
      version <- getParameter "version" V.fromString

      let directory = packageRoot name version
      exists <- liftIO $ doesDirectoryExist directory

      case exists of
        True -> serveFile (directory </> documentationPath)
        False -> httpError 404 "That library and version is not registered."


-- HELPERS

getParameter :: BSC.ByteString -> (String -> Maybe a) -> Snap a
getParameter param fromString =
  do  maybeValue <- getParam param
      let maybeString = fmap BSC.unpack maybeValue
      case fromString =<< maybeString of
        Just value -> return value
        Nothing ->
            httpError 400 $ BSC.concat [ "problem with parameter '", param, "'" ]


httpStringError :: Int -> String -> Snap a
httpStringError code msg =
    httpError code (BSC.pack msg)


httpError :: Int -> BSC.ByteString -> Snap a
httpError code msg = do
  modifyResponse $ setResponseStatus code msg
  finishWith =<< getResponse
