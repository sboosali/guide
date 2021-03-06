{-# LANGUAGE
ScopedTypeVariables,
QuasiQuotes,
OverloadedStrings,
GeneralizedNewtypeDeriving,
FlexibleContexts,
FlexibleInstances,
TypeFamilies,
NoImplicitPrelude
  #-}


{-# OPTIONS_GHC -fno-warn-orphans #-}


module Utils
(
  -- * Lists
  moveUp,
  moveDown,
  deleteFirst,
  insertAtGuaranteed,
  ordNub,

  -- * 'Eq'
  equating,

  -- * URLs
  Url,
  sanitiseUrl,
  makeSlug,

  -- * IP
  sockAddrToIP,
  
  -- * UID
  Uid(..),
  Node,
  randomShortUid,
  randomLongUid,
  uid_,

  -- * Lucid
  includeJS,
  includeCSS,

  -- * Spock
  atomFeed,

  -- * Template Haskell
  hs,
  dumpSplices,
  bangNotStrict,

  -- * Safecopy
  Change(..),
  TypeVersion(..),
  changelog,
  GenConstructor(..),
  genVer,
  MigrateConstructor(..),
  migrateVer,

  -- * Instances
  -- ** 'MonadThrow' for 'HtmlT'
)
where


import BasePrelude
-- Lists
import Data.List.Extra (stripSuffix)
-- Monads
import Control.Monad.Extra
-- Lenses
import Lens.Micro.Platform hiding ((&))
-- Monads and monad transformers
import Control.Monad.Trans
import Control.Monad.Catch
-- Containers
import qualified Data.Set as S
import qualified Data.Map as M
import Data.Map (Map)
-- Hashable (needed for Uid)
import Data.Hashable
-- Randomness
import System.Random
-- Text
import Data.Text.All (Text)
import qualified Data.Text.All as T
-- JSON
import qualified Data.Aeson as A
-- Network
import qualified Network.Socket as Network
import Data.IP
-- Web
import Lucid hiding (for_)
import Web.Spock
import Text.HTML.SanitizeXSS (sanitaryURI)
import Web.PathPieces
-- Feeds
import qualified Text.Atom.Feed        as Atom
import qualified Text.Atom.Feed.Export as Atom
import qualified Text.XML.Light.Output as XML
-- acid-state
import Data.SafeCopy
-- Template Haskell
import Language.Haskell.TH
import qualified Language.Haskell.TH.Syntax as TH (lift)
import Language.Haskell.TH.Quote (QuasiQuoter(..))
import Language.Haskell.Meta (parseExp)
import Data.Generics.Uniplate.Data (transform)


-- | Move the -1st element that satisfies the predicate- up.
moveUp :: (a -> Bool) -> [a] -> [a]
moveUp p (x:y:xs) = if p y then (y:x:xs) else x : moveUp p (y:xs)
moveUp _ xs = xs

-- | Move the -1st element that satisfies the predicate- down.
moveDown :: (a -> Bool) -> [a] -> [a]
moveDown p (x:y:xs) = if p x then (y:x:xs) else x : moveDown p (y:xs)
moveDown _ xs = xs

deleteFirst :: (a -> Bool) -> [a] -> [a]
deleteFirst _   []   = []
deleteFirst f (x:xs) = if f x then xs else x : deleteFirst f xs

insertAtGuaranteed :: Int -> a -> [a] -> [a]
insertAtGuaranteed _ a   []   = [a]
insertAtGuaranteed 0 a   xs   = a:xs
insertAtGuaranteed n a (x:xs) = x : insertAtGuaranteed (n-1) a xs

ordNub :: Ord a => [a] -> [a]
ordNub = go mempty
  where
    go _ [] = []
    go s (x:xs) | x `S.member` s = go s xs
                | otherwise      = x : go (S.insert x s) xs

equating :: Eq b => (a -> b) -> (a -> a -> Bool)
equating f = (==) `on` f

type Url = Text

sanitiseUrl :: Url -> Maybe Url
sanitiseUrl u
  | not (sanitaryURI u)       = Nothing
  | "http:" `T.isPrefixOf` u  = Just u
  | "https:" `T.isPrefixOf` u = Just u
  | otherwise                 = Just ("http://" <> u)

-- | Make text suitable for inclusion into an URL (by turning spaces into
-- hyphens and so on)
makeSlug :: Text -> Text
makeSlug =
  T.intercalate "-" . T.words .
  T.filter (\c -> isLetter c || isDigit c || c == ' ' || c == '-') .
  T.toLower .
  T.map (\x -> if x == '_' || x == '/' then '-' else x)

deriveSafeCopySimple 0 'base ''IPv4
deriveSafeCopySimple 0 'base ''IPv6
deriveSafeCopySimple 0 'base ''IP

sockAddrToIP :: Network.SockAddr -> Maybe IP
sockAddrToIP (Network.SockAddrInet  _   x)   = Just (IPv4 (fromHostAddress x))
sockAddrToIP (Network.SockAddrInet6 _ _ x _) = Just (IPv6 (fromHostAddress6 x))
sockAddrToIP _ = Nothing

-- | Unique id, used for many things – categories, items, and anchor ids.
newtype Uid a = Uid {uidToText :: Text}
  deriving (Eq, Ord, Show, PathPiece, T.Buildable, Hashable, A.ToJSON)

-- See Note [acid-state]
deriveSafeCopySimple 2 'extension ''Uid

newtype Uid_v1 a = Uid_v1 {uidToText_v1 :: Text}

-- TODO: at the next migration change this to deriveSafeCopySimple!
deriveSafeCopy 1 'base ''Uid_v1

instance SafeCopy a => Migrate (Uid a) where
  type MigrateFrom (Uid a) = Uid_v1 a
  migrate Uid_v1{..} = Uid {
    uidToText = uidToText_v1 }

instance IsString (Uid a) where
  fromString = Uid . T.pack

randomText :: MonadIO m => Int -> m Text
randomText n = liftIO $ do
  -- We don't want the 1st char to be a digit. Just in case (I don't really
  -- have a good reason). Maybe to prevent Javascript from doing automatic
  -- conversions or something (tho it should never happen).
  x <- randomRIO ('a', 'z')
  let randomChar = do
        i <- randomRIO (0, 35)
        return $ if i < 10 then toEnum (fromEnum '0' + i)
                           else toEnum (fromEnum 'a' + i - 10)
  xs <- replicateM (n-1) randomChar
  return (T.pack (x:xs))

randomLongUid :: MonadIO m => m (Uid a)
randomLongUid = Uid <$> randomText 12

-- These are only used for items and categories (because their uids can occur
-- in links and so they should look a bit nicer).
randomShortUid :: MonadIO m => m (Uid a)
randomShortUid = Uid <$> randomText 8

-- | A marker for Uids that would be used with HTML nodes
data Node

uid_ :: Uid Node -> Attribute
uid_ = id_ . uidToText

includeJS :: Monad m => Url -> HtmlT m ()
includeJS url = with (script_ "") [src_ url]

includeCSS :: Monad m => Url -> HtmlT m ()
includeCSS url = link_ [rel_ "stylesheet", type_ "text/css", href_ url]

atomFeed :: MonadIO m => Atom.Feed -> ActionCtxT ctx m ()
atomFeed feed = do
  setHeader "Content-Type" "application/atom+xml; charset=utf-8"
  bytes $ T.encodeUtf8 (T.pack (XML.ppElement (Atom.xmlFeed feed)))

hs :: QuasiQuoter
hs = QuasiQuoter {
  quoteExp  = either fail TH.lift . parseExp,
  quotePat  = fail "hs: can't parse patterns",
  quoteType = fail "hs: can't parse types",
  quoteDec  = fail "hs: can't parse declarations" }

dumpSplices :: DecsQ -> DecsQ
dumpSplices x = do
  ds <- x
  -- “reportWarning (pprint ds)” doesn't work in Emacs because of
  -- haskell-mode's parsing of compiler messages
  mapM_ (reportWarning . pprint) ds
  return ds

bangNotStrict :: Q Bang
bangNotStrict = bang noSourceUnpackedness noSourceStrictness

{- |
A change from one version of a record (one constructor, several fields) to
another version. We only record the latest version, so we have to be able to
reconstruct the previous version knowing the current version and a list of
'Change's.
-}
data Change
  -- | A field with a particular name and type was removed
  = Removed String (Q Type)
  -- | A field with a particular name and default value was added. We don't
  -- have to record the type since it's already known (remember, we know what
  -- the final version of the record is)
  | Added String Exp

data TypeVersion = Current Int | Past Int
  deriving (Show)

{- |
Generate previous version of the type.

Assume that the new type and the changelog are, respectively:

    -- version 4
    data Foo = FooRec {
      b :: Bool,
      c :: Int }

    changelog ''Foo (Current 4, Past 3) [
      Removed "a" [t|String|],
      Added "c" [|if null a then 0 else 1|] ]

Then we will generate a type called Foo_v3:

    data Foo_v3 = FooRec_v3 {
      a_v3 :: String,
      b_v3 :: Bool }

We'll also generate a migration instance:

    instance Migrate Foo where
      type MigrateFrom Foo = Foo_v3
      migrate old = FooRec {
        b = b_v3 old,
        c = if null (a_v3 old) then 0 else 1 }

Note that you must use 'deriveSafeCopySorted' for types that use 'changelog'
because otherwise fields will be parsed in the wrong order. Specifically,
imagine that you have created a type with fields “b” and “a” and then removed
“b”. 'changelog' has no way of knowing from “the current version has field
“a”” and “the previous version also had field “b”” that the previous version
had fields “b, a” and not “a, b”. Usual 'deriveSafeCopy' or
'deriveSafeCopySimple' care about field order and thus will treat “b, a” and
“a, b” as different types.
-}
changelog
  :: Name                        -- ^ Type (without version suffix)
  -> (TypeVersion, TypeVersion)  -- ^ New version, old version
  -> [Change]                    -- ^ List of changes between this version
                                 --   and previous one
  -> DecsQ
changelog _ (_newVer, Current _) _ =
  -- We could've just changed the second element of the tuple to be 'Int'
  -- instead of 'TypeVersion' but that would lead to worse-looking changelogs
  fail "changelog: old version can't be 'Current'"
changelog bareTyName (newVer, Past oldVer) changes = do
  -- ------------------------------------------------------------------------
  -- Name and version business
  -- ------------------------------------------------------------------------
  -- First, we can define functions for removing a new-version prefix and for
  -- adding a new/old-version prefix to a bare name. We'll be working with
  -- bare names everywhere.
  let mkBare :: Name -> String
      mkBare n = case newVer of
        Current _ -> nameBase n
        Past v ->
          let suff = ("_v" ++ show v)
          in case stripSuffix suff (nameBase n) of
               Just n' -> n'
               Nothing -> error $
                 printf "changelog: %s doesn't have suffix %s"
                        (show n) (show suff)
  let mkOld, mkNew :: String -> Name
      mkOld n = mkName (n ++ "_v" ++ show oldVer)
      mkNew n = case newVer of
        Current _ -> mkName n
        Past v -> mkName (n ++ "_v" ++ show v)
  -- We know the “base” name (tyName) of the type and we know the
  -- versions. From this we can get actual new/old names:
  let newTyName = mkNew (nameBase bareTyName)
  let oldTyName = mkOld (nameBase bareTyName)
  -- We should also check that the new version exists and that the old one
  -- doesn't.
  whenM (isNothing <$> lookupTypeName (nameBase newTyName)) $
    fail (printf "changelog: %s not found" (show newTyName))
  whenM (isJust <$> lookupTypeName (nameBase oldTyName)) $
    fail (printf "changelog: %s is already present" (show oldTyName))

  -- -----------------------------------------------------------------------
  -- Process the changelog
  -- -----------------------------------------------------------------------
  -- Make separate lists of added and removed fields
  let added :: Map String Exp
      added = M.fromList [(n, e) | Added n e <- changes]
  let removed :: Map String (Q Type)
      removed = M.fromList [(n, t) | Removed n t <- changes]

  -- -----------------------------------------------------------------------
  -- Get information about the new version of the datatype
  -- -----------------------------------------------------------------------
  -- First, 'reify' it. See documentation for 'reify' to understand why we
  -- use 'lookupValueName' here (if we just do @reify newTyName@, we might
  -- get the constructor instead).
  TyConI (DataD _cxt _name _vars _kind cons _deriving) <- do
    mbReallyTyName <- lookupTypeName (nameBase newTyName)
    case mbReallyTyName of
      Just reallyTyName -> reify reallyTyName
      Nothing -> fail $ printf "changelog: type %s not found" (show newTyName)
  -- Do some checks first – we only have to handle simple types for now, but
  -- if/when we need to handle more complex ones, we want to be warned.
  unless (null _cxt) $
    fail "changelog: can't yet work with types with context"
  unless (null _vars) $
    fail "changelog: can't yet work with types with variables"
  unless (isNothing _kind) $
    fail "changelog: can't yet work with types with kinds"
  -- We assume that the type is a single-constructor record.
  con <- case cons of
    [x] -> return x
    []  -> fail "changelog: the type has to have at least one constructor"
    _   -> fail "changelog: the type has to have only one constructor"
  -- Check that the type is actually a record and that there are no strict
  -- fields (which we cannot handle yet); when done, make a list of fields
  -- that is easier to work with. We strip names to their bare form.
  let normalBang = Bang NoSourceUnpackedness NoSourceStrictness
  (recName :: String, fields :: [(String, Type)]) <- case con of
    RecC cn fs
      | all (== normalBang) (fs^..each._2) ->
          return (mkBare cn, [(mkBare n, t) | (n,_,t) <- fs])
      | otherwise -> fail "changelog: can't work with strict/unpacked fields"
    _             -> fail "changelog: the type must be a record"
  -- Check that all 'Added' fields are actually present in the new type
  -- and that all 'Removed' fields aren't there
  for_ (M.keys added) $ \n -> do
    unless (n `elem` map fst fields) $ fail $
      printf "changelog: field %s isn't present in %s"
             (show (mkNew n)) (show newTyName)
  for_ (M.keys removed) $ \n -> do
    when (n `elem` map fst fields) $ fail $
      printf "changelog: field %s is present in %s \
             \but was supposed to be removed"
             (show (mkNew n)) (show newTyName)

  -- -----------------------------------------------------------------------
  -- Generate the old type
  -- -----------------------------------------------------------------------
  -- Now we can generate the old type based on the new type and the
  -- changelog. First we determine the list of fields (and types) we'll have
  -- by taking 'fields' from the new type, adding 'Removed' fields and
  -- removing 'Added' fields. We still use bare names everywhere.
  let oldFields :: Map String (Q Type)
      oldFields = fmap return (M.fromList fields)
                    `M.union` removed
                    `M.difference` added

  -- Then we construct the record constructor:
  --   FooRec_v3 { a_v3 :: String, b_v3 :: Bool }
  let oldRec = recC (mkOld recName)
                    [varBangType (mkOld fName)
                                 (bangType bangNotStrict fType)
                    | (fName, fType) <- M.toList oldFields]
  -- And the data type:
  --   data Foo_v3 = FooRec_v3 {...}
  let oldTypeDecl = dataD (cxt [])      -- no context
                          oldTyName     -- name of old type
                          []            -- no variables
                          Nothing       -- no explicit kind
                          [oldRec]      -- one constructor
                          (cxt [])      -- not deriving anything

  -- Next we generate the migration instance. It has two inner declarations.
  -- First declaration – “type MigrateFrom Foo = Foo_v3”:
  let migrateFromDecl =
        tySynInstD ''MigrateFrom (tySynEqn [conT newTyName] (conT oldTyName))
  -- Second declaration:
  --   migrate old = FooRec {
  --     b = b_v3 old,
  --     c = if null (a_v3 old) then 0 else 1 }
  migrateArg <- newName "old"
  -- This function replaces accessors in an expression – “a” turns into
  -- “(a_vN old)” if 'a' is one of the fields in the old type
  let replaceAccessors = transform f
        where f (VarE x) | nameBase x `elem` M.keys oldFields =
                AppE (VarE (mkOld (nameBase x))) (VarE migrateArg)
              f x = x
  let migrateDecl = funD 'migrate [
        clause [varP migrateArg]
          (normalB $ recConE (mkNew recName) $ do
             (field, _) <- fields
             let content = case M.lookup field added of
                   -- the field was present in old type
                   Nothing -> appE (varE (mkOld field)) (varE migrateArg)
                   -- wasn't
                   Just e  -> return (replaceAccessors e)
             return $ (mkNew field,) <$> content)
          []
        ]

  let migrateInstanceDecl =
        instanceD
          (cxt [])                        -- no context
          [t|Migrate $(conT newTyName)|]  -- Migrate Foo
          [migrateFromDecl, migrateDecl]  -- associated type & migration func

  -- Return everything
  sequence [oldTypeDecl, migrateInstanceDecl]

data GenConstructor = Copy Name | Custom String [(String, Name)]

genVer :: Name -> Int -> [GenConstructor] -> Q [Dec]
genVer tyName ver constructors = do
  -- Get information about the new version of the datatype
  TyConI (DataD _cxt _name _vars _kind cons _deriving) <- reify tyName
  -- Let's do some checks first
  unless (null _cxt) $
    fail "genVer: can't yet work with types with context"
  unless (null _vars) $
    fail "genVer: can't yet work with types with variables"
  unless (isNothing _kind) $
    fail "genVer: can't yet work with types with kinds"

  let oldName n = mkName (nameBase n ++ "_v" ++ show ver)

  let copyConstructor conName =
        case [c | c@(RecC n _) <- cons, n == conName] of
          [] -> fail ("genVer: couldn't find a record constructor " ++
                      show conName)
          [RecC _ fields] ->
            recC (oldName conName)
                 (map return (fields & each._1 %~ oldName))
          other -> fail ("genVer: copyConstructor: got " ++ show other)

  let customConstructor conName fields =
        recC (oldName (mkName conName))
             [varBangType (oldName (mkName fName))
                          (bangType bangNotStrict (conT fType))
               | (fName, fType) <- fields]

  cons' <- for constructors $ \genCons -> do
    case genCons of
      Copy conName -> copyConstructor conName
      Custom conName fields -> customConstructor conName fields

  decl <- dataD
    -- no context
    (cxt [])
    -- name of our type (e.g. SomeType_v3 if the previous version was 3)
    (oldName tyName)
    -- no variables
    []
    -- no explicit kind
    Nothing
    -- constructors
    (map return cons')
    -- not deriving anything
    (cxt [])
  return [decl]

data MigrateConstructor = CopyM Name | CustomM Name ExpQ

migrateVer :: Name -> Int -> [MigrateConstructor] -> Q Exp
migrateVer tyName ver constructors = do
  -- Get information about the new version of the datatype
  TyConI (DataD _cxt _name _vars _kind cons _deriving) <- reify tyName
  -- Let's do some checks first
  unless (null _cxt) $
    fail "migrateVer: can't yet work with types with context"
  unless (null _vars) $
    fail "migrateVer: can't yet work with types with variables"
  unless (isNothing _kind) $
    fail "migrateVer: can't yet work with types with kinds"

  let oldName n = mkName (nameBase n ++ "_v" ++ show ver)

  arg <- newName "x"

  let copyConstructor conName =
        case [c | c@(RecC n _) <- cons, n == conName] of
          [] -> fail ("migrateVer: couldn't find a record constructor " ++
                      show conName)
          [RecC _ fields] -> do
            -- SomeConstr_v3{} -> SomeConstr (field1 x) (field2 x) ...
            let getField f = varE (oldName (f ^. _1)) `appE` varE arg
            match (recP (oldName conName) [])
                  (normalB (appsE (conE conName : map getField fields)))
                  []
          other -> fail ("migrateVer: copyConstructor: got " ++ show other)

  let customConstructor conName res =
        match (recP (oldName conName) [])
              (normalB res)
              []

  branches' <- for constructors $ \genCons -> do
    case genCons of
      CopyM conName -> copyConstructor conName
      CustomM conName res -> customConstructor conName res

  lam1E (varP arg) (caseE (varE arg) (map return branches'))

instance MonadThrow m => MonadThrow (HtmlT m) where
  throwM e = lift $ throwM e
