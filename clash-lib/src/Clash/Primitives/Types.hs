{-|
  Copyright  :  (C) 2012-2016, University of Twente,
                    2016-2017, Myrtle Software Ltd
                    2018     , Google Inc.
                    2021     , QBayLogic B.V.
                    2022     , Google Inc.
  License    :  BSD2 (see the file LICENSE)
  Maintainer :  QBayLogic B.V. <devops@qbaylogic.com>

  Type and instance definitions for Primitive
-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Clash.Primitives.Types
  ( TemplateSource(..)
  , TemplateKind(..)
  , TemplateFormat(..)
  , BlackBoxFunctionName(..)
  , Primitive(..)
  , UsedArguments(..)
  , GuardedCompiledPrimitive
  , GuardedResolvedPrimitive
  , PrimMap
  , UnresolvedPrimitive
  , ResolvedPrimitive
  , ResolvedPrimMap
  , CompiledPrimitive
  , CompiledPrimMap
  ) where

import {-# SOURCE #-} Clash.Netlist.Types (BlackBox, Usage(..))
import           Clash.Annotations.Primitive  (PrimitiveGuard)
import           Clash.Core.Term (WorkInfo (..))
import           Clash.Netlist.BlackBox.Types
  (BlackBoxFunction, BlackBoxTemplate, TemplateKind (..), RenderVoid(..))
import           Control.Applicative          ((<|>))
import           Control.DeepSeq              (NFData)
import           Control.Monad                (when)
import           Data.Aeson
  (FromJSON (..), Value (..), (.:), (.:?), (.!=))
import           Data.Aeson.Types             (Parser)
import           Data.Binary                  (Binary)
import           Data.Char                    (isUpper, isLower, isAlphaNum)
import           Data.Either                  (lefts)
import           Data.Hashable                (Hashable)
import qualified Data.HashMap.Strict          as H
import           Data.List                    (intercalate)
import           Data.Maybe                   (isJust)
import qualified Data.Text                    as S
import           Data.Text.Lazy               (Text)
import           GHC.Generics                 (Generic)
import           GHC.Stack                    (HasCallStack)
import           Text.Read                    (readMaybe)

#if MIN_VERSION_aeson(2,0,0)
import qualified Data.Aeson.KeyMap as KeyMap
#endif

-- | An unresolved primitive still contains pointers to files.
type UnresolvedPrimitive = Primitive Text ((TemplateFormat,BlackBoxFunctionName),Maybe TemplateSource) (Maybe S.Text) (Maybe TemplateSource)

-- | A parsed primitive does not contain pointers to filesystem files anymore,
-- but holds uncompiled @BlackBoxTemplate@s and @BlackBoxFunction@s.
type ResolvedPrimitive        = Primitive Text ((TemplateFormat,BlackBoxFunctionName),Maybe Text) () (Maybe Text)
type GuardedResolvedPrimitive = PrimitiveGuard ResolvedPrimitive
type ResolvedPrimMap          = PrimMap GuardedResolvedPrimitive

-- | A compiled primitive has compiled all templates and functions from its
-- @ResolvedPrimitive@ counterpart. The Int in the tuple is a hash of the
-- (uncompiled) BlackBoxFunction.
type CompiledPrimitive        = Primitive BlackBoxTemplate BlackBox () (Int, BlackBoxFunction)
type GuardedCompiledPrimitive = PrimitiveGuard CompiledPrimitive
type CompiledPrimMap          = PrimMap GuardedCompiledPrimitive

-- | A @PrimMap@ maps primitive names to a @Primitive@
type PrimMap a = H.HashMap S.Text a

-- | A BBFN is a parsed version of a fully qualified function name. It is
-- guaranteed to have at least one module name which is not /Main/.
data BlackBoxFunctionName =
  BlackBoxFunctionName [String] String
    deriving (Eq, Generic, NFData, Binary, Hashable)

instance Show BlackBoxFunctionName where
  show (BlackBoxFunctionName mods funcName) =
    "BBFN<" ++ intercalate "." mods ++ "." ++ funcName ++ ">"

-- | Quick and dirty implementation of Text.splitOn for Strings
splitOn :: String -> String -> [String]
splitOn (S.pack -> sep) (S.pack -> str) =
  map S.unpack $ S.splitOn sep str

-- | Parses a string into a list of modules and a function name. I.e., it parses
-- the string 'Clash.Primitives.Types.parseBBFN' to
-- @["Clash", "Primitives",Types"]@ and @"parseBBFN"@.
-- The result is stored as a BlackBoxFunctionName.
parseBBFN
  :: HasCallStack
  => String
  -> Either String BlackBoxFunctionName
parseBBFN bbfn =
  case splitOn "." bbfn of
    []  -> Left $ "Empty function name: " ++ bbfn
    [_] -> Left $ "No module or function defined: " ++ bbfn
    nms ->
      let (mods, func) = (init nms, last nms) in
      let errs = lefts $ checkFunc func : map checkMod mods in
      case errs of
        [] -> Right $ BlackBoxFunctionName mods func
        e:_ -> Left $ "Error while parsing " ++ show bbfn ++ ": " ++ e
  where
    checkMod mod'
      | m':_ <- mod'
      , isLower m' =
          Left $ "Module name cannot start with lowercase: " ++ mod'
      | any (not . isAlphaNum) mod' =
          Left $ "Module name must be alphanumerical: " ++ mod'
      | otherwise =
          Right mod'

    checkFunc func
      | f:_ <- func
      , isUpper f =
          Left $ "Function name must start with lowercase: " ++ func
      | otherwise =
          Right func

data TemplateSource
  = TFile FilePath
  -- ^ Template source stored in file on filesystem
  | TInline Text
  -- ^ Template stored inline
  deriving (Show, Eq, Hashable, Generic, NFData)


data TemplateFormat
  = TTemplate
  | THaskell
  deriving (Show, Generic, Eq, Hashable, NFData)

-- | Data type to indicate what arguments are in use by a BlackBox
data UsedArguments
  = UsedArguments [Int]
  -- ^ Only these are used
  | IgnoredArguments [Int]
  -- ^ All but these are used
  deriving (Show, Generic, Eq, Hashable, NFData, Binary)

-- | Externally defined primitive
data Primitive a b c d
  -- | Primitive template written in a Clash specific templating language
  = BlackBox
  { name      :: !S.Text
    -- ^ Name of the primitive
  , workInfo  :: WorkInfo
    -- ^ Whether the primitive does any work, i.e. takes chip area
  , renderVoid :: RenderVoid
    -- ^ Whether this primitive should be rendered when its result type is
    -- void. Defaults to 'NoRenderVoid'.
  , multiResult :: Bool
    -- ^ Wether this blackbox assigns its results to multiple variables. See
    -- 'Clash.Normalize.Transformations.setupMultiResultPrim'
  , kind      :: TemplateKind
    -- ^ Whether this results in an expression or a declaration
  , warning  :: c
    -- ^ A warning to be outputted when the primitive is instantiated.
    -- This is intended to be used as a warning for primitives that are not
    -- synthesizable, but may also be used for other purposes.
  , outputUsage :: Usage
    -- ^ How the result is assigned in HDL. This is used to determine the
    -- type of declaration used to render the result (wire/reg or
    -- signal/variable). The default usage is continuous assignment.
  , libraries :: [a]
    -- ^ VHDL only: add /library/ declarations for the given names
  , imports   :: [a]
    -- ^ VHDL only: add /use/ declarations for the given names
  , functionPlurality :: [(Int, Int)]  -- Using map ruins Hashable instance
    -- ^ Indicates how often a function will be instantiated in a blackbox. For
    -- example, consider the following higher-order function that creates a tree
    -- structure:
    --
    --   fold :: (a -> a -> a) -> Vec n a -> a
    --
    -- In order to generate HDL for an instance of fold we need log2(n) calls
    -- to the first argument, `a -> a -> a` (plus a few more if n is not a
    -- power of two). Note that this only targets multiple textual instances
    -- of the function. If you can generate the HDL using a for-loop and only
    -- need to call ~INST once, you don't have to worry about this option. See
    -- the blackbox for 'Clash.Sized.Vector.map' for an example of this.
    --
    -- Right now, option can only be generated by BlackBoxHaskell. It cannot be
    -- used within JSON primitives. To see how to use this, see the Haskell
    -- blackbox for 'Clash.Sized.Vector.fold'.
  , includes  :: [((S.Text,S.Text),b)]
    -- ^ Create files to be included with the generated primitive. The fields
    -- are ((name, extension), content), where content is a template of the file
    -- Defaults to @[]@ when not specified in the /.primitives/ file
  , resultNames :: [b]
    -- ^ (Maybe) Control the generated name of the result
  , resultInits :: [b]
    -- ^ (Maybe) Control the initial/power-up value of the result
  , template :: b
    -- ^ Used to indiciate type of template (declaration or expression). Will be
    -- filled with @Template@ or an @Either decl expr@.
  }
  -- | Primitive template rendered by a Haskell function (given as raw source code)
  | BlackBoxHaskell
  { name :: !S.Text
    -- ^ Name of the primitive
  , workInfo  :: WorkInfo
    -- ^ Whether the primitive does any work, i.e. takes chip area
  , usedArguments :: UsedArguments
  -- ^ Arguments used by blackbox. Used to remove arguments during normalization.
  , multiResult :: Bool
  -- ^ Wether this blackbox assigns its results to multiple variables. See
  -- 'Clash.Normalize.Transformations.setupMultiResultPrim'
  , functionName :: BlackBoxFunctionName
  , function :: d
  -- ^ Holds blackbox function and its hash, (Int, BlackBoxFunction), in a
  -- CompiledPrimitive.
  }
  -- | A primitive that carries additional information. These are "real"
  -- primitives, hardcoded in the compiler. For example: 'mapSignal' in
  -- @GHC2Core.coreToTerm@.
  | Primitive
  { name     :: !S.Text
    -- ^ Name of the primitive
  , workInfo  :: WorkInfo
    -- ^ Whether the primitive does any work, i.e. takes chip area
  , primSort :: !Text
    -- ^ Additional information
  }
  deriving (Show, Generic, NFData, Binary, Eq, Hashable, Functor)

instance FromJSON UnresolvedPrimitive where
  parseJSON (Object v) =
#if MIN_VERSION_aeson(2,0,0)
    case KeyMap.toList v of
#else
    case H.toList v of
#endif
      [(conKey,Object conVal)] ->
        case conKey of
          "BlackBoxHaskell"  -> do
            usedArgs <- conVal .:? "usedArguments"
            ignoredArgs <- conVal .:? "ignoredArguments"
            args <-
              case (usedArgs, ignoredArgs) of
                (Nothing, Nothing) -> pure (IgnoredArguments [])
                (Just a, Nothing) -> pure (UsedArguments a)
                (Nothing, Just a) -> pure (IgnoredArguments a)
                (Just _, Just _) ->
                  fail "[8] Don't use both 'usedArguments' and 'ignoredArguments'"

            name' <- conVal .: "name"
            wf    <- ((conVal .:? "workInfo" >>= maybe (pure Nothing) parseWorkInfo) .!= WorkVariable)
            fName <- conVal .: "templateFunction"
            isMultiResult <- conVal .:? "multiResult" .!= False
            templ <- (Just . TInline <$> conVal .: "template")
                 <|> (Just . TFile   <$> conVal .: "file")
                 <|> (pure Nothing)
            fName' <- either fail return (parseBBFN fName)
            return (BlackBoxHaskell name' wf args isMultiResult fName' templ)
          "BlackBox"  -> do
            outReg <- conVal .:? "outputReg" :: Parser (Maybe Bool)

            when (isJust outReg) .
              fail $ mconcat
                [ "[9] 'outputReg' is no longer a recognized key.\n"
                , "Use 'outputUsage: Continuous|NonBlocking|Blocking' instead."
                ]

            BlackBox <$> conVal .: "name"
                     <*> (conVal .:? "workInfo" >>= maybe (pure Nothing) parseWorkInfo) .!= WorkVariable
                     <*> conVal .:? "renderVoid" .!= NoRenderVoid
                     <*> conVal .:? "multiResult" .!= False
                     <*> (conVal .: "kind" >>= parseTemplateKind)
                     <*> conVal .:? "warning"
                     <*> conVal .:? "outputUsage" .!= Cont
                     <*> conVal .:? "libraries" .!= []
                     <*> conVal .:? "imports" .!= []
                     <*> pure [] -- functionPlurality not supported in json
                     <*> (conVal .:? "includes" .!= [] >>= traverse parseInclude)
                     <*> (conVal .:? "resultName" >>= maybe (pure Nothing) parseResult) .!= []
                     <*> (conVal .:? "resultInit" >>= maybe (pure Nothing) parseResult) .!= []
                     <*> parseTemplate conVal
          "Primitive" ->
            Primitive <$> conVal .: "name"
                      <*> (conVal .:? "workInfo" >>= maybe (pure Nothing) parseWorkInfo) .!= WorkVariable
                      <*> conVal .: "primType"

          e -> fail $ "[1] Expected: BlackBox or Primitive object, got: " ++ show e
      e -> fail $ "[2] Expected: BlackBox or Primitive object, got: " ++ show e
    where
      parseTemplate c =
        (,) <$> ((,) <$> (c .:? "format" >>= traverse parseTemplateFormat) .!= TTemplate
                     <*> (c .:? "templateFunction" >>= traverse parseBBFN') .!= defTemplateFunction)
            <*> (Just . TInline <$> c .: "template" <|>
                 Just . TFile   <$> c .: "file" <|>
                 pure Nothing)

      parseInclude c =
        (,) <$> ((,) <$> c .: "name" <*> c .: "extension")
            <*> parseTemplate c

      parseTemplateKind (String "Declaration") = pure TDecl
      parseTemplateKind (String "Expression")  = pure TExpr
      parseTemplateKind c = fail ("[4] Expected: Declaration or Expression, got " ++ show c)

      parseTemplateFormat (String "Template") = pure TTemplate
      parseTemplateFormat (String "Haskell")  = pure THaskell
      parseTemplateFormat c = fail ("[5] unexpected format: " ++ show c)

      parseWorkInfo (String "Constant") = pure (Just WorkConstant)
      parseWorkInfo (String "Never")    = pure (Just WorkNever)
      parseWorkInfo (String "Variable") = pure (Just WorkVariable)
      parseWorkInfo (String "Always")   = pure (Just WorkAlways)
      parseWorkInfo (parseWorkIdentity -> wi@Just{}) = pure wi
      parseWorkInfo c = fail ("[6] unexpected workInfo: " ++ show c)

      parseWorkIdentity arg = do
        String str   <- return arg
        [iStr,xsStr] <- words . S.unpack <$> S.stripPrefix "Identity" str
        WorkIdentity <$> readMaybe iStr <*> readMaybe xsStr

      parseBBFN' = either fail return . parseBBFN

      defTemplateFunction = BlackBoxFunctionName ["Template"] "template"

      parseResult (Object c) =
        Just . pure <$> parseTemplate c
      parseResult e = fail $ "[7] unexpected result: " ++ show e

  parseJSON unexpected =
    fail $ "[3] Expected: BlackBox or Primitive object, got: " ++ show unexpected
