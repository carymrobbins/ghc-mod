module GHCMod.Options (
  parseArgs,
  parseCommandsFromList,
  GhcModCommands(..)
) where

import Options.Applicative
import Options.Applicative.Types
import Language.Haskell.GhcMod.Types
import Control.Arrow
import GHCMod.Options.Commands
import GHCMod.Version

parseArgs :: IO (Options, GhcModCommands)
parseArgs =
  execParser opts
  where
    opts = info (argAndCmdSpec <**> helpVersion)
      ( fullDesc
     <> header "ghc-mod: Happy Haskell Programming" )

parseCommandsFromList :: [String] -> Either String GhcModCommands
parseCommandsFromList args =
  case execParserPure (prefs idm) (info commandsSpec idm) args of
    Success a -> Right a
    Failure h -> Left $ show h
    CompletionInvoked _ -> error "WTF"

helpVersion :: Parser (a -> a)
helpVersion =
  helper <*>
  abortOption (InfoMsg ghcModVersion)
    (long "version" <> help "Print the version of the program.") <*>
  argument r (value id <> metavar "")
  where
    r :: ReadM (a -> a)
    r = do
      v <- readerAsk
      case v of
        "help" -> readerAbort ShowHelpText
        "version" -> readerAbort $ InfoMsg ghcModVersion
        _ -> return id

argAndCmdSpec :: Parser (Options, GhcModCommands)
argAndCmdSpec = (,) <$> globalArgSpec <*> commandsSpec

splitOn :: Eq a => a -> [a] -> ([a], [a])
splitOn c = second (drop 1) . break (==c)

getLogLevel :: Int -> GmLogLevel
getLogLevel = toEnum . min 7

logLevelParser :: Parser GmLogLevel
logLevelParser =
  getLogLevel <$>
    (
    silentSwitch <|> logLevelSwitch <|> logLevelOption
    )
  where
    logLevelOption =
      option int (
        long "verbose" <>
        metavar "LEVEL" <>
        value 4 <>
        showDefault <>
        help "Set log level. (0-7)"
      )
    logLevelSwitch =
      (4+) . length <$> many (flag' () (
        short 'v' <>
        help "Increase log level"
      ))
    silentSwitch = flag' 0 (
        long "silent" <>
        short 's' <>
        help "Be silent, set log level to 0"
      )

outputOptsSpec :: Parser OutputOpts
outputOptsSpec = OutputOpts <$>
      logLevelParser <*>
      flag PlainStyle LispStyle (
        long "tolisp" <>
        short 'l' <>
        help "Format output as an S-Expression"
      ) <*>
      (LineSeparator <$> strOption (
        long "boundary" <>
        long "line-separator" <>
        short 'b' <>
        metavar "SEP" <>
        value "\0" <>
        showDefault <>
        help "Output line separator"
      )) <*>
      optional (splitOn ',' <$> strOption (
        long "line-prefix" <>
        metavar "OUT,ERR" <>
        help "Output prefixes"
      ))

programsArgSpec :: Parser Programs
programsArgSpec = Programs <$>
      strOption (
        long "with-ghc" <>
        value "ghc" <>
        showDefault <>
        help "GHC executable to use"
      ) <*>
      strOption (
        long "with-ghc-pkg" <>
        value "ghc-pkg" <>
        showDefault <>
        help "ghc-pkg executable to use (only needed when guessing from GHC path fails)"
      ) <*>
      strOption (
        long "with-cabal" <>
        value "cabal" <>
        showDefault <>
        help "cabal-install executable to use"
      ) <*>
      strOption (
        long "with-stack" <>
        value "stack" <>
        showDefault <>
        help "stack executable to use"
      )

globalArgSpec :: Parser Options
globalArgSpec = Options <$>
      outputOptsSpec <*> -- optOutput
      programsArgSpec <*> -- optPrograms
      many (strOption ( -- optGhcUserOptions
        long "ghcOpt" <>
        long "ghc-option" <>
        short 'g' <>
        metavar "OPT" <>
        help "Option to be passed to GHC"
      )) <*>
      many fileMappingSpec -- optFileMappings   = []
  where
    {-
    File map docs:

    CLI options:
    * `--map-file "file1.hs=file2.hs"` can be used to tell
        ghc-mod that it should take source code for `file1.hs` from `file2.hs`.
        `file1.hs` can be either full path, or path relative to project root.
        `file2.hs` has to be either relative to project root,
        or full path (preferred).
    * `--map-file "file.hs"` can be used to tell ghc-mod that it should take
        source code for `file.hs` from stdin. File end marker is `\EOT\n`,
        i.e. `\x04\x0A`. `file.hs` may or may not exist, and should be
        either full path, or relative to project root.

    Interactive commands:
    * `map-file file.hs` -- tells ghc-modi to read `file.hs` source from stdin.
        Works the same as second form of `--map-file` CLI option.
    * `unmap-file file.hs` -- unloads previously mapped file, so that it's
        no longer mapped. `file.hs` can be full path or relative to
        project root, either will work.

    Exposed functions:
    * `loadMappedFile :: FilePath -> FilePath -> GhcModT m ()` -- maps `FilePath`,
        given as first argument to take source from `FilePath` given as second
        argument. Works exactly the same as first form of `--map-file`
        CLI option.
    * `loadMappedFileSource :: FilePath -> String -> GhcModT m ()` -- maps
        `FilePath`, given as first argument to have source as given
        by second argument. Works exactly the same as second form of `--map-file`
        CLI option, sans reading from stdin.
    * `unloadMappedFile :: FilePath -> GhcModT m ()` -- unmaps `FilePath`, given as
        first argument, and removes any temporary files created when file was
        mapped. Works exactly the same as `unmap-file` interactive command
    -}
    fileMappingSpec =
      getFileMapping . splitOn '=' <$> strOption (
        long "map-file" <>
        metavar "MAPPING" <>
        help "Redirect one file to another, --map-file \"file1.hs=file2.hs\""
      )
    getFileMapping = second (\i -> if null i then Nothing else Just i)
