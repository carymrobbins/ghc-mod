-- ghc-mod: Making Haskell development *more* fun
-- Copyright (C) 2015  Daniel Gröber <dxld ÄT darkboxed DOT org>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

module Language.Haskell.GhcMod.CabalHelper (
    CabalHelper(..)
  , getComponents
  , getGhcOptions
  , getGhcPkgOptions
  , cabalHelper
  ) where

import Control.Applicative
import Control.Arrow
import Control.Monad
import Data.Monoid
import Data.List
import Language.Haskell.GhcMod.Types
import Language.Haskell.GhcMod.Monad.Types
import Language.Haskell.GhcMod.Error as E
import Language.Haskell.GhcMod.Utils
import Language.Haskell.GhcMod.World
import Language.Haskell.GhcMod.PathsAndFiles
import System.FilePath
import System.Process

-- | Only package related GHC options, sufficient for things that don't need to
-- access home modules
getGhcPkgOptions :: (MonadIO m, GmEnv m) => m [(GmComponentName, [GHCOption])]
getGhcPkgOptions = chGhcPkgOptions `liftM` cabalHelper

getGhcOptions :: (MonadIO m, GmEnv m) => m [(GmComponentName, [GHCOption])]
getGhcOptions = chGhcOptions `liftM` cabalHelper

-- | Primary interface to cabal-helper and intended single entrypoint to
-- constructing 'GmComponent's
--
-- The Component\'s 'gmcHomeModuleGraph' will be empty and has to be resolved by
-- 'resolveGmComponents'.
getComponents :: (MonadIO m, GmEnv m)
    => m [GmComponent (Either FilePath [ModuleName])]
getComponents = cabalHelper >>= \CabalHelper {..} -> return $ let
  ([(scn, sep)], eps) = partition ((GmSetupHsName ==) . fst) chEntrypoints
  sc = GmComponent scn [] [] sep sep ["."] mempty
  cs = flip map (zip4 eps chGhcOptions chGhcSrcOptions chSourceDirs) $
      \((cn, ep), (_, opts), (_, srcOpts), (_, srcDirs)) ->
          GmComponent cn opts srcOpts ep ep srcDirs mempty
  in sc:cs

withCabal :: (MonadIO m, GmEnv m) => m a -> m a
withCabal action = do
    crdl <- cradle
    opts <- options
    liftIO $ whenM (isSetupConfigOutOfDate <$> getCurrentWorld crdl) $
        withDirectory_ (cradleRootDir crdl) $ do
            let progOpts =
                    [ "--with-ghc=" ++ ghcProgram opts ]
                    -- Only pass ghc-pkg if it was actually set otherwise we
                    -- might break cabal's guessing logic
                    ++ if ghcPkgProgram opts /= ghcPkgProgram defaultOptions
                         then [ "--with-ghc-pkg=" ++ ghcPkgProgram opts ]
                         else []
            void $ readProcess (cabalProgram opts) ("configure":progOpts) ""
    action

data CabalHelper = CabalHelper {
      chEntrypoints   :: [(GmComponentName, Either FilePath [ModuleName])],
      chSourceDirs    :: [(GmComponentName, [String])],
      chGhcOptions    :: [(GmComponentName, [String])],
      chGhcSrcOptions :: [(GmComponentName, [String])],
      chGhcPkgOptions :: [(GmComponentName, [String])]
    } deriving (Show)

cabalHelper :: (MonadIO m, GmEnv m) => m CabalHelper
cabalHelper = withCabal $ do
  Cradle {..} <- cradle
  Options {..} <- options
  let progArgs = [ "--with-ghc="     ++ ghcProgram
                 , "--with-ghc-pkg=" ++ ghcPkgProgram
                 , "--with-cabal="   ++ cabalProgram
                 ]

  let args = [ "entrypoints"
             , "source-dirs"
             , "ghc-options"
             , "ghc-src-options"
             , "ghc-pkg-options"
             ] ++ progArgs

      distdir = cradleRootDir </> "dist"

  liftIO $ hPutStrLn stderr $ show args
  res <- liftIO $ do
    exe  <- findLibexecExe "cabal-helper-wrapper"
    hexe <- readProcess exe ([distdir, "print-exe"] ++ progArgs) ""

    cached cradleRootDir (cabalHelperCache hexe args) $ do
        out <- readProcess exe (distdir:args) ""
        evaluate (read out) `E.catch`
            \(SomeException _) -> error "cabalHelper: read failed"

  let [ Just (GmCabalHelperEntrypoints eps),
        Just (GmCabalHelperStrings srcDirs),
        Just (GmCabalHelperStrings ghcOpts),
        Just (GmCabalHelperStrings ghcSrcOpts),
        Just (GmCabalHelperStrings ghcPkgOpts) ] = res
      eps' = map (second $ fmap $ map md) eps

  return $ CabalHelper eps' srcDirs ghcOpts ghcSrcOpts ghcPkgOpts

 where
   md (GmModuleName mn) = mkModuleName mn
