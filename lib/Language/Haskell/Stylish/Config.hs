--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Language.Haskell.Stylish.Config
    ( Extensions
    , Config (..)
    , defaultConfigBytes
    , configFilePath
    , loadConfig
    ) where


--------------------------------------------------------------------------------
import           Control.Monad                                    (forM, mzero)
import           Data.Aeson                                       (FromJSON (..))
import qualified Data.Aeson                                       as A
import qualified Data.Aeson.Types                                 as A
import qualified Data.ByteString                                  as B
import           Data.ByteString.Lazy                             (fromStrict)
import           Data.Char                                        (toLower)
import qualified Data.FileEmbed                                   as FileEmbed
import           Data.List                                        (intercalate,
                                                                   nub)
import           Data.Map                                         (Map)
import qualified Data.Map                                         as M
import           Data.Maybe                                       (fromMaybe)
import qualified Data.Text                                        as T
import           Data.YAML                                        (prettyPosWithSource)
import           Data.YAML.Aeson                                  (decode1Strict)
import           System.Directory
import           System.FilePath                                  ((</>))
import qualified System.IO                                        as IO (Newline (..),
                                                                         nativeNewline)
import           Text.Read                                        (readMaybe)


--------------------------------------------------------------------------------
import qualified Language.Haskell.Stylish.Config.Cabal            as Cabal
import           Language.Haskell.Stylish.Config.Internal
import           Language.Haskell.Stylish.Step
import qualified Language.Haskell.Stylish.Step.Data               as Data
import qualified Language.Haskell.Stylish.Step.Imports            as Imports
import qualified Language.Haskell.Stylish.Step.Imports'           as Imports'
import qualified Language.Haskell.Stylish.Step.ModuleHeader       as ModuleHeader
import qualified Language.Haskell.Stylish.Step.LanguagePragmas    as LanguagePragmas
import qualified Language.Haskell.Stylish.Step.SimpleAlign        as SimpleAlign
import qualified Language.Haskell.Stylish.Step.Squash             as Squash
import qualified Language.Haskell.Stylish.Step.Tabs               as Tabs
import qualified Language.Haskell.Stylish.Step.TrailingWhitespace as TrailingWhitespace
import qualified Language.Haskell.Stylish.Step.UnicodeSyntax      as UnicodeSyntax
import           Language.Haskell.Stylish.Verbose


--------------------------------------------------------------------------------
type Extensions = [String]


--------------------------------------------------------------------------------
data Config = Config
    { configSteps              :: [Step]
    , configColumns            :: Maybe Int
    , configLanguageExtensions :: [String]
    , configNewline            :: IO.Newline
    , configCabal              :: Bool
    }

--------------------------------------------------------------------------------
instance FromJSON Config where
    parseJSON = parseConfig


--------------------------------------------------------------------------------
configFileName :: String
configFileName = ".stylish-haskell.yaml"


--------------------------------------------------------------------------------
defaultConfigBytes :: B.ByteString
defaultConfigBytes = $(FileEmbed.embedFile "data/stylish-haskell.yaml")


--------------------------------------------------------------------------------
configFilePath :: Verbose -> Maybe FilePath -> IO (Maybe FilePath)
configFilePath _       (Just userSpecified) = return (Just userSpecified)
configFilePath verbose Nothing              = do
    current    <- getCurrentDirectory
    configPath <- getXdgDirectory XdgConfig "stylish-haskell"
    home       <- getHomeDirectory
    search verbose $
        [d </> configFileName | d <- ancestors current] ++
        [configPath </> "config.yaml", home </> configFileName]

search :: Verbose -> [FilePath] -> IO (Maybe FilePath)
search _ []             = return Nothing
search verbose (f : fs) = do
    -- TODO Maybe catch an error here, dir might be unreadable
    exists <- doesFileExist f
    verbose $ f ++ if exists then " exists" else " does not exist"
    if exists then return (Just f) else search verbose fs

--------------------------------------------------------------------------------
loadConfig :: Verbose -> Maybe FilePath -> IO Config
loadConfig verbose userSpecified = do
    mbFp <- configFilePath verbose userSpecified
    verbose $ "Loading configuration at " ++ fromMaybe "<embedded>" mbFp
    bytes <- maybe (return defaultConfigBytes) B.readFile mbFp
    case decode1Strict bytes of
        Left (pos, err)     -> error $ prettyPosWithSource pos (fromStrict bytes) ("Language.Haskell.Stylish.Config.loadConfig: " ++ err)
        Right config -> do
          cabalLanguageExtensions <- if configCabal config
            then map show <$> Cabal.findLanguageExtensions verbose
            else pure []

          return $ config
            { configLanguageExtensions = nub $
                configLanguageExtensions config ++ cabalLanguageExtensions
            }


--------------------------------------------------------------------------------
parseConfig :: A.Value -> A.Parser Config
parseConfig (A.Object o) = do
    -- First load the config without the actual steps
    config <- Config
        <$> pure []
        <*> (o A..:! "columns"             A..!= Just 80)
        <*> (o A..:? "language_extensions" A..!= [])
        <*> (o A..:? "newline"             >>= parseEnum newlines IO.nativeNewline)
        <*> (o A..:? "cabal"               A..!= True)

    -- Then fill in the steps based on the partial config we already have
    stepValues <- o A..: "steps" :: A.Parser [A.Value]
    steps      <- mapM (parseSteps config) stepValues
    return config {configSteps = concat steps}
  where
    newlines =
        [ ("native", IO.nativeNewline)
        , ("lf",     IO.LF)
        , ("crlf",   IO.CRLF)
        ]
parseConfig _            = mzero


--------------------------------------------------------------------------------
catalog :: Map String (Config -> A.Object -> A.Parser Step)
catalog = M.fromList $
  if False then
    [ ("imports",             parseImports)
    , ("records",             parseRecords)
    , ("language_pragmas",    parseLanguagePragmas)
    , ("simple_align",        parseSimpleAlign)
    , ("squash",              parseSquash)
    , ("tabs",                parseTabs)
    , ("trailing_whitespace", parseTrailingWhitespace)
    , ("unicode_syntax",      parseUnicodeSyntax)
    ]
  else
    -- Done:
    [ ("imports",       parseImports')
    , ("module_header", parseModuleHeader)
    , ("tabs",          parseTabs)
    , ("trailing_whitespace", parseTrailingWhitespace)
    ]
    -- To be ported:
    --   * data (records)
    --   * language_pragmas
    --   * simple_align
    --   * squash
    --   * unicode_syntax


--------------------------------------------------------------------------------
parseSteps :: Config -> A.Value -> A.Parser [Step]
parseSteps config val = do
    map' <- parseJSON val :: A.Parser (Map String A.Value)
    forM (M.toList map') $ \(k, v) -> case (M.lookup k catalog, v) of
        (Just parser, A.Object o) -> parser config o
        _                         -> fail $ "Invalid declaration for " ++ k


--------------------------------------------------------------------------------
-- | Utility for enum-like options
parseEnum :: [(String, a)] -> a -> Maybe String -> A.Parser a
parseEnum _    def Nothing  = return def
parseEnum strs _   (Just k) = case lookup k strs of
    Just v  -> return v
    Nothing -> fail $ "Unknown option: " ++ k ++ ", should be one of: " ++
        intercalate ", " (map fst strs)

--------------------------------------------------------------------------------
parseModuleHeader :: Config -> A.Object -> A.Parser Step
parseModuleHeader _ _
  = pure
  . ModuleHeader.step
  $ ModuleHeader.Config

--------------------------------------------------------------------------------
parseSimpleAlign :: Config -> A.Object -> A.Parser Step
parseSimpleAlign c o = SimpleAlign.step
    <$> pure (configColumns c)
    <*> (SimpleAlign.Config
        <$> withDef SimpleAlign.cCases            "cases"
        <*> withDef SimpleAlign.cTopLevelPatterns "top_level_patterns"
        <*> withDef SimpleAlign.cRecords          "records")
  where
    withDef f k = fromMaybe (f SimpleAlign.defaultConfig) <$> (o A..:? k)

--------------------------------------------------------------------------------
parseRecords :: Config -> A.Object -> A.Parser Step
parseRecords _ o = Data.step
    <$> (Data.Config
        <$> (o A..: "equals" >>= parseIndent)
        <*> (o A..: "first_field" >>= parseIndent)
        <*> (o A..: "field_comment")
        <*> (o A..: "deriving"))


parseIndent :: A.Value -> A.Parser Data.Indent
parseIndent = A.withText "Indent" $ \t ->
  if t == "same_line"
     then return Data.SameLine
     else
         if "indent " `T.isPrefixOf` t
             then
                 case readMaybe (T.unpack $ T.drop 7 t) of
                     Just n -> return $ Data.Indent n
                     Nothing -> fail $ "Indent: not a number" <> T.unpack (T.drop 7 t)
             else fail $ "can't parse indent setting: " <> T.unpack t


--------------------------------------------------------------------------------
parseSquash :: Config -> A.Object -> A.Parser Step
parseSquash _ _ = return Squash.step


--------------------------------------------------------------------------------
parseImports :: Config -> A.Object -> A.Parser Step
parseImports config o = Imports.step
    <$> pure (configColumns config)
    <*> (Imports.Options
        <$> (o A..:? "align" >>= parseEnum aligns (def Imports.importAlign))
        <*> (o A..:? "list_align" >>= parseEnum listAligns (def Imports.listAlign))
        <*> (o A..:? "pad_module_names" A..!= def Imports.padModuleNames)
        <*> (o A..:? "long_list_align"
            >>= parseEnum longListAligns (def Imports.longListAlign))
        -- Note that padding has to be at least 1. Default is 4.
        <*> (o A..:? "empty_list_align"
            >>= parseEnum emptyListAligns (def Imports.emptyListAlign))
        <*> o A..:? "list_padding" A..!= def Imports.listPadding
        <*> o A..:? "separate_lists" A..!= def Imports.separateLists
        <*> o A..:? "space_surround" A..!= def Imports.spaceSurround)
  where
    def f = f Imports.defaultOptions

    aligns =
        [ ("global", Imports.Global)
        , ("file",   Imports.File)
        , ("group",  Imports.Group)
        , ("none",   Imports.None)
        ]

    listAligns =
        [ ("new_line",          Imports.NewLine)
        , ("with_module_name",  Imports.WithModuleName)
        , ("with_alias",        Imports.WithAlias)
        , ("after_alias",       Imports.AfterAlias)
        ]

    longListAligns =
        [ ("inline",             Imports.Inline)
        , ("new_line",           Imports.InlineWithBreak)
        , ("new_line_multiline", Imports.InlineToMultiline)
        , ("multiline",          Imports.Multiline)
        ]

    emptyListAligns =
        [ ("inherit", Imports.Inherit)
        , ("right_after", Imports.RightAfter)
        ]

--------------------------------------------------------------------------------
parseImports' :: Config -> A.Object -> A.Parser Step
parseImports' _ _
  = pure
  . Imports'.step
  $ Imports'.Config

--------------------------------------------------------------------------------
parseLanguagePragmas :: Config -> A.Object -> A.Parser Step
parseLanguagePragmas config o = LanguagePragmas.step
    <$> pure (configColumns config)
    <*> (o A..:? "style" >>= parseEnum styles LanguagePragmas.Vertical)
    <*> o A..:? "align"            A..!= True
    <*> o A..:? "remove_redundant" A..!= True
    <*> mkLanguage o
  where
    styles =
        [ ("vertical",     LanguagePragmas.Vertical)
        , ("compact",      LanguagePragmas.Compact)
        , ("compact_line", LanguagePragmas.CompactLine)
        ]


--------------------------------------------------------------------------------
-- | Utilities for validating language prefixes
mkLanguage :: A.Object -> A.Parser String
mkLanguage o = do
    lang <- o A..:? "language_prefix"
    maybe (pure "LANGUAGE") validate lang
    where
        validate :: String -> A.Parser String
        validate s
            | fmap toLower s == "language" = pure s
            | otherwise = fail "please provide a valid language prefix"


--------------------------------------------------------------------------------
parseTabs :: Config -> A.Object -> A.Parser Step
parseTabs _ o = Tabs.step
    <$> o A..:? "spaces" A..!= 8


--------------------------------------------------------------------------------
parseTrailingWhitespace :: Config -> A.Object -> A.Parser Step
parseTrailingWhitespace _ _ = return TrailingWhitespace.step


--------------------------------------------------------------------------------
parseUnicodeSyntax :: Config -> A.Object -> A.Parser Step
parseUnicodeSyntax _ o = UnicodeSyntax.step
    <$> o A..:? "add_language_pragma" A..!= True
    <*> mkLanguage o
