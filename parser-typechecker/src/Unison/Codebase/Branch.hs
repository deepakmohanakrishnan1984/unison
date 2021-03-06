
{-# LANGUAGE DoAndIfThenElse     #-}
{-# LANGUAGE PatternSynonyms     #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE ViewPatterns        #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Unison.Codebase.Branch where

-- import Unison.Codebase.NameEdit (NameEdit)

import           Control.Monad            (foldM, join)
import           Data.Bifunctor           (bimap)
import           Data.Foldable
import           Data.Functor.Identity    (runIdentity)
import           Data.Map                 (Map)
import qualified Data.Map                 as Map
import           Data.Set                 (Set)
import qualified Data.Set                 as Set
import           Prelude                  hiding (head)
import           Unison.Codebase.Causal   (Causal)
import qualified Unison.Codebase.Causal   as Causal
import           Unison.Codebase.TermEdit (TermEdit, Typing)
import qualified Unison.Codebase.TermEdit as TermEdit
import           Unison.Codebase.TypeEdit (TypeEdit)
import qualified Unison.Codebase.TypeEdit as TypeEdit
import           Unison.Hash              (Hash)
import           Unison.Hashable          (Hashable)
import qualified Unison.Hashable          as H
import           Unison.Names             (Name, Names (..))
import qualified Unison.Names             as Names
import           Unison.Reference         (Reference)
import           Unison.Referent          (Referent)
import qualified Unison.Referent          as Referent
import qualified Unison.UnisonFile        as UF
import           Unison.Util.Relation     (Relation)
import qualified Unison.Util.Relation     as R
-- import qualified Unison.Term as Term
import           Unison.PrettyPrintEnv    (PrettyPrintEnv (..))
import           Unison.Var               (Var)
import qualified Unison.Var               as Var
--import Data.Semigroup (sconcat)
--import Data.List.NonEmpty (nonEmpty)

-- todo:
-- probably should refactor Reference to include info about whether it
-- is a term reference, a type decl reference, or an effect decl reference
-- (maybe combine last two)
--
-- While we're at it, should add a `Cycle Int [Reference]` for referring to
-- an element of a cycle of references.
--
-- If we do that, can implement various operations safely since we'll know
-- if we are referring to a term or a type (and can prevent adding a type
-- reference to the term namespace, say)

-- A `Branch`, `b` should likely maintain that:
--
--  * If `r : Reference` is in `codebase b` or one of its
--    transitive dependencies then `b` should have a `Name` for `r`.
--
-- This implies that if you depend on some code, you pick names for that
-- code. The editing tool will likely pick names based on some convention.
-- (like if you import and use `Runar.foo` in a function you write, it will
--  republished under `dependencies.Runar`. Could also potentially put
--  deps alongside the namespace...)
--
-- Thought was that basically don't need `Release`, it's just that
-- some branches are unconflicted and we might indicate that in some way
-- in the UI.
--
-- To "delete" a definition, just remove it from the map.
--
-- Operations around making transitive updates, resolving conflicts...
-- determining remaining work before one branch "covers" another...
newtype Branch = Branch { unbranch :: Causal Branch0 } deriving (Eq, Show)

data RefCollisions =
  RefCollisions { termCollisions :: Relation Name Name
                , patternCollisions :: Relation Name Name
                , typeCollisions :: Relation Name Name
                } deriving (Eq, Show)

data Branch0 =
  Branch0 { termNamespace    :: Relation Name Referent
          , patternNamespace :: Relation Name (Reference,Int)
          , typeNamespace    :: Relation Name Reference
          , editedTerms      :: Relation Reference TermEdit
          , editedTypes      :: Relation Reference TypeEdit
          } deriving (Eq, Show)

one :: Branch0 -> Branch
one = Branch . Causal.one

allNamedReferences :: Branch0 -> Set Reference
allNamedReferences b = let
  termRefs = Set.map Referent.toReference (R.ran (termNamespace b))
  typeRefs = R.ran (typeNamespace b)
  in termRefs <> typeRefs

allNamedTypes :: Branch0 -> Set Reference
allNamedTypes b = R.ran (typeNamespace b)

data Diff = Diff { ours :: Branch0, theirs :: Branch0 }

fromNames :: Names -> Branch0
fromNames names = Branch0 terms pats types R.empty R.empty
 where
  terms = R.fromList . Map.toList $ Names.termNames names
  pats  = R.fromList . Map.toList $ Names.patternNames names
  types = R.fromList . Map.toList $ Names.typeNames names

contains :: Branch0 -> Reference -> Bool
contains b r = R.memberRan (Referent.Ref r) (termNamespace b)
  || R.memberRan r (typeNamespace b)

diff :: Branch -> Branch -> Diff
diff ours theirs =
  uncurry diff' $ join bimap (Causal.head . unbranch) (ours, theirs)

diff' :: Branch0 -> Branch0 -> Diff
diff' ours theirs =
  let to :: (Ord a, Ord b) => Set (a,b) -> Relation a b
      to               = R.fromSet
      fro :: (Ord a, Ord b) => Relation a b -> Set (a, b)
      fro              = R.toSet
      diffSet f =
        ( to (fro (f ours) `Set.difference` fro (f theirs))
        , to (fro (f theirs) `Set.difference` fro (f ours))
        )
      (ourTerms    , theirTerms    ) = diffSet termNamespace
      (ourPats     , theirPats     ) = diffSet patternNamespace
      (ourTypes    , theirTypes    ) = diffSet typeNamespace
      (ourTermEdits, theirTermEdits) = diffSet editedTerms
      (ourTypeEdits, theirTypeEdits) = diffSet editedTypes
  in  Diff (Branch0 ourTerms ourPats ourTypes ourTermEdits ourTypeEdits)
           (Branch0 theirTerms theirPats theirTypes theirTermEdits theirTypeEdits)

-- When adding a Reference `r` to a namespace as `n`:
--   * add names for all of its transitive dependencies to `backupNames`.
--   * cache its transitive dependencies in `transitiveDependencies`
--   * (q1) do we add r,n to backupNames? no
-- When removing a Reference `r` from a namespace:
--   * get its transitive dependencies `ds`
--   * remove `r` from dom(transitiveDependencies)
--   * for each `d <- ds`, if `d` isn't in ran(transitiveDependencies),
--                         then delete `d` from backupNames
--   * (q2) When renaming, do we need to update `backupNames`? no

instance Semigroup Branch0 where
  Branch0 n1 p1 nt1 e1 et1 <> Branch0 n2 p2 nt2 e2 et2 = Branch0
    (R.union n1 n2)
    (R.union p1 p2)
    (R.union nt1 nt2)
    (R.union e1 e2)
    (R.union et1 et2)

instance Monoid Branch0 where
  mempty = Branch0 R.empty R.empty R.empty R.empty R.empty
  mappend = (<>)

allNames :: Branch0 -> Set Name
allNames b0 =
  R.dom (termNamespace b0) `Set.union`
  R.dom (typeNamespace b0) `Set.union`
  R.dom (patternNamespace b0)

allTermNames :: Branch0 -> Set Name
allTermNames b0 = R.dom (termNamespace b0)

allTypeNames :: Branch0 -> Set Name
allTypeNames b0 = R.dom (typeNamespace b0)

hasTermNamed :: Name -> Branch -> Bool
hasTermNamed n b = not . null $ termsNamed n b

hasTypeNamed :: Name -> Branch -> Bool
hasTypeNamed n b = not . null $ typesNamed n b

hasPatternNamed :: Name -> Branch -> Bool
hasPatternNamed n b = not . null $ patternsNamed n b

termsNamed :: Name -> Branch -> Set Referent
termsNamed name = R.lookupDom name . termNamespace . Causal.head . unbranch

typesNamed :: Name -> Branch -> Set Reference
typesNamed name = R.lookupDom name . typeNamespace . Causal.head . unbranch

patternsNamed :: Name -> Branch -> Set (Reference, Int)
patternsNamed name =
  R.lookupDom name . patternNamespace . Causal.head . unbranch

namesForTerm :: Referent -> Branch -> Set Name
namesForTerm ref = R.lookupRan ref . termNamespace . Causal.head . unbranch

namesForType :: Reference -> Branch -> Set Name
namesForType ref = R.lookupRan ref . typeNamespace . Causal.head . unbranch

namesForPattern :: Reference -> Int -> Branch -> Set Name
namesForPattern ref cid =
  R.lookupRan (ref, cid) . patternNamespace . Causal.head . unbranch

prettyPrintEnv1 :: Branch -> PrettyPrintEnv
prettyPrintEnv1 b = PrettyPrintEnv terms patterns types where
  terms r = multiset $ namesForTerm r b
  patterns r cid = multiset $ namesForPattern r cid b
  types r = multiset $ namesForType r b
  multiset ks = Map.fromList [ (k, 1) | k <- Set.toList ks ]

prettyPrintEnv :: [Branch] -> PrettyPrintEnv
prettyPrintEnv = foldMap prettyPrintEnv1

before :: Branch -> Branch -> Bool
before b b2 = unbranch b `Causal.before` unbranch b2

-- Use e.g. by `conflicts termNamespace branch`
conflicts :: Ord a => (Branch0 -> Relation a b) -> Branch -> Map a (Set b)
conflicts f = conflicts' . f . Causal.head . unbranch where
  conflicts' :: Ord a => Relation a b -> Map a (Set b)
  conflicts' r =
    -- iterate over the domain, looking for ranges with size > 1
    -- build a map of those sets
    foldl' go Map.empty (R.dom r) where
      go m a =
        let bs = R.lookupDom a r
        in if Set.size bs > 1 then Map.insert a bs m else m

conflicts' :: Branch -> Branch0
conflicts' b = Branch0 (c termNamespace)
                       (c patternNamespace)
                       (c typeNamespace)
                       (c editedTerms)
                       (c editedTypes)
  where c f = R.fromMultimap . conflicts f $ b


-- Use as `resolved editedTerms branch`
resolved :: Ord a => (Branch0 -> Relation a b) -> Branch -> Map a b
resolved f = resolved' . f . Causal.head . unbranch where
  resolved' :: Ord a => Relation a b -> Map a b
  resolved' r = foldl' go Map.empty (R.dom r) where
    go m a =
      let bs = R.lookupDom a r
      in if Set.size bs == 1 then Map.insert a (Set.findMin bs) m else m


-- count of remaining work, including:
-- * conflicted thingies
-- * among unconflicted thingies:
--    * definitions depending on definitions that have been updated
--       * terms and types depending on updated types
--       * terms depending on updated terms
data RemainingWork
  = TermNameConflict Name (Set Referent)
  | TypeNameConflict Name (Set Reference)
  | TermEditConflict Reference (Set TermEdit)
  | TypeEditConflict Reference (Set TypeEdit)
  -- ObsoleteTerm r [(old,new)]: r depended on old, which has been updated to new
  | ObsoleteTerm Reference (Set (Reference, Either TermEdit TypeEdit))
  | ObsoleteType Reference (Set (Reference, TypeEdit))
  deriving (Eq, Ord, Show)

remaining :: forall m. Monad m => ReferenceOps m -> Branch -> m (Set RemainingWork)
remaining ops b@(Branch (Causal.head -> b0)) = do
-- If any of r's dependencies have been updated, r should be updated.
-- Alternatively: If `a` has been edited, then all of a's dependents
-- should be edited. (Maybe a warning if they are updated to something
-- that still uses `a`.)
  -- map from updated term to dependent + termedit
  (obsoleteTerms, obsoleteTypes) <- wrangleUpdatedTypes ops =<< wrangleUpdatedTerms
  pure . Set.fromList $
    (uncurry TermNameConflict <$> Map.toList (conflicts termNamespace b)) ++
    (uncurry TypeNameConflict <$> Map.toList (conflicts typeNamespace b)) ++
    (uncurry TermEditConflict <$> Map.toList (conflicts editedTerms b)) ++
    (uncurry TypeEditConflict <$> Map.toList (conflicts editedTypes b)) ++
    (uncurry ObsoleteTerm <$> Map.toList obsoleteTerms) ++
    (uncurry ObsoleteType <$> Map.toList obsoleteTypes)
  where                    -- referent -> (oldreference, edit)
    wrangleUpdatedTerms :: m (Map Reference (Set (Reference, Either TermEdit TypeEdit)))
    wrangleUpdatedTerms =
      -- 1. filter the edits to find the ones that are resolved (not conflicted)
      -- 2. for each resolved (oldref,edit) pair,
      -- 2b.  look up the referents of that oldref.
      -- 2c.  if the referent is unedited, add it to the work:
      -- 2c(i).  add it to the term work list if it's a term ref,
      -- 2c(ii). only terms can depend on terms, so it's a term ref.
      let termEdits :: Map Reference TermEdit -- oldreference, edit
          termEdits = resolved editedTerms b
          transitiveDependents :: Reference -> m (Set Reference)
          transitiveDependents r = transitiveClosure1 (dependents ops) r
          isEdited r = R.memberDom r (editedTerms b0)
          uneditedTransitiveDependents :: Reference -> m [Reference]
          uneditedTransitiveDependents r =
            filter (not . isEdited) . toList <$> transitiveDependents r
          asSingleton :: Reference -> TermEdit -> Reference -> Map Reference (Set (Reference, Either TermEdit TypeEdit))
          asSingleton oldRef edit referent = Map.singleton referent (Set.singleton (oldRef, Left edit))
          workFromEdit :: (Reference, TermEdit) -> m (Map Reference (Set (Reference, Either TermEdit TypeEdit)))
          workFromEdit (oldRef, edit) =
            mconcat . fmap (asSingleton oldRef edit) <$> uneditedTransitiveDependents oldRef
      in fmap mconcat (traverse workFromEdit $ Map.toList termEdits)

    wrangleUpdatedTypes ::
      Monad m => ReferenceOps m
              -> Map Reference (Set (Reference, Either TermEdit TypeEdit))
              -> m (Map Reference (Set (Reference, Either TermEdit TypeEdit))
                   ,Map Reference (Set (Reference, TypeEdit)))
    wrangleUpdatedTypes ops initialTermEdits =
      -- 1. filter the edits to find the ones that are resolved (not conflicted)
      -- 2. for each resolved (oldref,edit) pair,
      -- 2b.  look up the referents of that oldref.
      -- 2c.  if the referent is unedited, add it to the work:
      -- 2c(i).  add it to the term work list if it's a term ref,
      -- 2c(ii). add it to the type work list if it's a type ref
      foldM go (initialTermEdits, Map.empty) (Map.toList typeEdits)
      where
        typeEdits :: Map Reference TypeEdit -- oldreference, edit
        typeEdits = resolved editedTypes b
        go :: Monad m
           => (Map Reference (Set (Reference, Either TermEdit TypeEdit))
                ,Map Reference (Set (Reference, TypeEdit)))
           -> (Reference, TypeEdit)
           -> m (Map Reference (Set (Reference, Either TermEdit TypeEdit))
                ,Map Reference (Set (Reference, TypeEdit)))
        go (termWork, typeWork) (oldRef, edit) =
          foldM go2 (termWork, typeWork) =<<
                    (transitiveClosure1 (dependents ops) oldRef) where
            single referent oldRef edit =
              Map.singleton referent (Set.singleton (oldRef, edit))
            singleRight referent oldRef edit =
              Map.singleton referent (Set.singleton (oldRef, Right edit))
            go2 :: (Map Reference (Set (Reference, Either TermEdit TypeEdit))
                   ,Map Reference (Set (Reference, TypeEdit)))
                -> Reference
                -> m (Map Reference (Set (Reference, Either TermEdit TypeEdit))
                     ,Map Reference (Set (Reference, TypeEdit)))
            go2 (termWorkAcc, typeWorkAcc) referent =
              termOrTypeOp ops referent
                (pure $
                  if not $ R.memberDom referent (editedTerms b0)
                  then (termWorkAcc <> singleRight referent oldRef edit, typeWorkAcc)
                  else (termWorkAcc, typeWorkAcc))
                (pure $
                  if not $ R.memberDom referent (editedTypes b0)
                  then (termWorkAcc, typeWorkAcc <> single referent oldRef edit)
                  else (termWorkAcc, typeWorkAcc))

empty :: Branch
empty = Branch (Causal.one mempty)

merge :: Branch -> Branch -> Branch
merge (Branch b) (Branch b2) = Branch (Causal.merge b b2)


head :: Branch -> Branch0
head (Branch b) = Causal.head b

-- Returns the subset of `b0` whose names collide with elements of `b`
nameCollisions :: Branch0 -> Branch -> Branch0
nameCollisions b0 b = go b0 (head b) where
  -- `set R.<| rel` filters `rel` to contain tuples whose first elem is in `set`
  go b1 b2 = Branch0
    (Set.intersection (R.dom $ termNamespace b1) (R.dom $ termNamespace b2) R.<| termNamespace b1)
    (Set.intersection (R.dom $ patternNamespace b1) (R.dom $ patternNamespace b2) R.<| patternNamespace b1)
    (Set.intersection (R.dom $ typeNamespace b1) (R.dom $ typeNamespace b2) R.<| typeNamespace b1)
    R.empty
    R.empty

-- Returns names occurring in both branches that also have the same referent.
duplicates :: Branch0 -> Branch -> Branch0
duplicates b0 b = go b0 (head b)
 where
  terms    = R.toSet . termNamespace
  types    = R.toSet . typeNamespace
  patterns = R.toSet . patternNamespace
  go b1 b2 = Branch0
    (R.fromSet . Set.intersection (terms b1) $ terms b2)
    (R.fromSet . Set.intersection (patterns b1) $ patterns b2)
    (R.fromSet . Set.intersection (types b1) $ types b2)
    R.empty
    R.empty

-- Returns the subset of `b0` whose names collide with elements of `b`
-- (and don't have the same referent).
collisions :: Branch0 -> Branch -> Branch0
collisions b0 b = ours $ nameCollisions b0 b `diff'` duplicates b0 b

-- Returns the references that have different names in `a` vs `b`
differentNames :: Branch0 -> Branch -> RefCollisions
differentNames a b = RefCollisions collTerms collPats collTypes
 where
  hb = head b
  colls f b =
    R.fromMultimap
      . fmap
          (Set.unions . toList . Set.map
            (\n -> Set.fromList . toList . R.lookupRan n $ f b)
          )
      . R.domain
      . f
  collTerms = colls termNamespace hb a
  collPats  = colls patternNamespace hb a
  collTypes = colls typeNamespace hb a

-- Returns the subset of `b0` whose referents collide with elements of `b`
refCollisions :: Branch0 -> Branch -> Branch0
refCollisions b0 b = ours . diff' (go b0 $ head b) $ duplicates b0 b
 where
  -- `set R.<| rel` filters `rel` to contain tuples whose first elem is in `set`
  go b1 b2 = Branch0
    (    termNamespace b1
    R.|> (Set.intersection (R.ran $ termNamespace b1)
                           (R.ran $ termNamespace b2)
         )
    )
    (    patternNamespace b1
    R.|> (Set.intersection (R.ran $ patternNamespace b1)
                           (R.ran $ patternNamespace b2)
         )
    )
    (    typeNamespace b1
    R.|> (Set.intersection (R.ran $ typeNamespace b1)
                           (R.ran $ typeNamespace b2)
         )
    )
    R.empty
    R.empty

-- todo: treat name collisions as edits to a branch
-- editsFromNameCollisions :: Codebase -> Branch0 -> Branch -> Branch

-- Promote a typechecked file to a `Branch0` which can be added to a `Branch`
fromTypecheckedFile :: forall v a. Var v => UF.TypecheckedUnisonFile v a -> Branch0
fromTypecheckedFile file = let
  toName = Var.name
  hashedTerms = UF.hashTerms file
  ctors :: [(v, Referent)]
  ctors = Map.toList $ UF.hashConstructors file
  conNamespace = R.fromList [ (toName v, r) | (v, r@(Referent.Con _ _)) <- ctors ]
  reqNamespace = R.fromList [ (toName v, r) | (v, r@(Referent.Req _ _)) <- ctors ]
  patternNamespace =
    R.fromList ([ (toName v, (r,i)) | (v, (Referent.Con r i)) <- ctors ] <>
                [ (toName v, (r,i)) | (v, (Referent.Req r i)) <- ctors ])
  termNamespace1 = R.fromList [ (toName v, Referent.Ref r) | (v, (r, _, _)) <- Map.toList hashedTerms ]
  typeNamespace1 = R.fromList [ (toName v, r) | (v, (r, _)   ) <- Map.toList (UF.dataDeclarations' file) ]
  typeNamespace2 = R.fromList [ (toName v, r) | (v, (r, _)   ) <- Map.toList (UF.effectDeclarations' file) ]
  in Branch0 (termNamespace1 `R.union` conNamespace `R.union` reqNamespace)
             patternNamespace
             (typeNamespace1 `R.union` typeNamespace2)
             R.empty
             R.empty

-- | Returns the types and terms, respectively, whose names occur in both
-- the branch and the file.
intersectWithFile
  :: forall v a
   . Var v
  => Branch0
  -> UF.TypecheckedUnisonFile v a
  -> (Set v, Set v)
intersectWithFile branch file =
  ( Set.union
    (Map.keysSet (UF.dataDeclarations' file) `Set.intersection` typeNames)
    (Map.keysSet (UF.effectDeclarations' file) `Set.intersection` typeNames)
  , Set.fromList
    $   UF.topLevelComponents file
    >>= (>>= (\(v, _, _) -> if Set.member v termNames then [v] else []))
  )
 where
  typeNames = Set.map (Var.named) $ allTypeNames branch
  termNames = Set.map (Var.named) $ allTermNames branch


modify :: (Branch0 -> Branch0) -> Branch -> Branch
modify f (Branch b) = Branch $ Causal.step f b

append :: Branch0 -> Branch -> Branch
append b0 = modify (<> b0)

instance Semigroup Branch where
  (<>) = mappend

instance Monoid Branch where
  mempty = empty
  mappend = merge

data ReferenceOps m = ReferenceOps
  { isTerm       :: Reference -> m Bool
  , isType       :: Reference -> m Bool
  , dependencies :: Reference -> m (Set Reference)
  , dependents   :: Reference -> m (Set Reference)
  }

-- 0. bar depends on foo
-- 1. replace foo with foo'
-- 2. replace bar with bar' which depends on foo'
-- 3. replace foo' with foo''
-- "foo" points to foo''
-- "bar" points to bar'
--
-- foo -> Replace foo'
-- foo' -> Replace foo''
-- bar -> Replace bar'
--
-- foo -> Replace foo''
-- foo' -> Replace foo''
-- bar -> Replace bar'
--
-- foo -> Replace foo''
-- bar -> Replace bar''
-- foo' -> Replace foo'' *optional
-- bar' -> Replace bar'' *optional

replaceType :: Reference -> Reference -> Branch -> Branch
replaceType old new (Branch b) = Branch $ Causal.step go b where
  go b = b { editedTypes = R.insert old (TypeEdit.Replace new) (editedTypes b)
           , typeNamespace = R.replaceRan old new $ typeNamespace b
           }

-- insertNames :: Monad m
--             => ReferenceOps m
--             -> Relation Reference Name
--             -> Reference -> m (Relation Reference Name)
-- insertNames ops m r = foldl' (flip $ R.insert r) m <$> name ops r

replaceTerm :: Reference -> Reference -> Typing -> Branch -> Branch
replaceTerm old new typ (Branch b) = Branch $ Causal.step go b where
  old' = Referent.Ref old
  new' = Referent.Ref new
  edit = TermEdit.Replace new typ
  go b = b { editedTerms = R.insert old edit (editedTerms b)
           , termNamespace = R.replaceRan old' new' $ termNamespace b
           }

-- If any `as` aren't in `b`, then delete them from `c` as well.  Kind of sad.
deleteOrphans
  :: (Ord a, Ord c) => Set a -> Relation a b -> Relation a c -> Relation a c
deleteOrphans as b c =
  foldl' (\c a -> if R.memberDom a b then c else R.deleteDom a c) c as

-- Collect all the term/type references mentioned in this branch.
codebase :: Monad m => ReferenceOps m -> Branch -> m (Set Reference)
codebase ops (Branch (Causal.head -> Branch0 {..})) =
  let initial = Set.fromList $
        (Referent.toReference . snd <$> R.toList termNamespace) ++
        (snd <$> R.toList typeNamespace) ++
        ((map snd (R.toList editedTerms) >>= TermEdit.referents)) ++
        ((map snd (R.toList editedTypes) >>= TypeEdit.references))
  in transitiveClosure (dependencies ops) initial

transitiveClosure :: forall m a. (Monad m, Ord a)
                  => (a -> m (Set a))
                  -> Set a
                  -> m (Set a)
transitiveClosure getDependencies open =
  let go :: Set a -> [a] -> m (Set a)
      go closed [] = pure closed
      go closed (h:t) =
        if Set.member h closed
          then go closed t
        else do
          deps <- getDependencies h
          go (Set.insert h closed) (toList deps ++ t)
  in go Set.empty (toList open)

transitiveClosure1 :: forall m a. (Monad m, Ord a)
                   => (a -> m (Set a)) -> a -> m (Set a)
transitiveClosure1 f a = transitiveClosure f (Set.singleton a)

transitiveClosure1' :: Ord a => (a -> Set a) -> a -> Set a
transitiveClosure1' f a = runIdentity $ transitiveClosure1 (pure.f) a

deprecateTerm :: Reference -> Branch -> Branch
deprecateTerm old (Branch b) = Branch $ Causal.step go b where
  go b = b { editedTerms = R.insert old TermEdit.Deprecate (editedTerms b)
           , termNamespace = R.deleteRan (Referent.Ref old) (termNamespace b)
           }


deprecateType :: Reference -> Branch -> Branch
deprecateType old (Branch b) = Branch $ Causal.step go b where
  go b = b { editedTypes = R.insert old TypeEdit.Deprecate (editedTypes b)
           , typeNamespace = R.deleteRan old (typeNamespace b)
           }

instance (Hashable a, Hashable b) => Hashable (Relation a b) where
  tokens r = H.tokens (R.toList r)

instance Hashable Branch0 where
  tokens (Branch0 {..}) =
    H.tokens termNamespace ++ H.tokens typeNamespace ++
    H.tokens editedTerms ++ H.tokens editedTypes

resolveTerm :: Name -> Branch -> Set Referent
resolveTerm n (Branch (Causal.head -> b)) = R.lookupDom n (termNamespace b)

resolveTermUniquely :: Name -> Branch -> Maybe Referent
resolveTermUniquely n b =
  case resolveTerm n b of
    s | Set.size s == 1 -> Set.lookupMin s
    _                   -> Nothing

termOrTypeOp :: Monad m => ReferenceOps m -> Reference
             -> m b -> m b -> m b
termOrTypeOp ops r ifTerm ifType = do
  isTerm <- isTerm ops r
  isType <- isType ops r
  if isTerm then ifTerm
  else if isType then ifType
  else fail $ "neither term nor type: " ++ show r

addTermName :: Referent -> Name -> Branch -> Branch
addTermName r new (Branch b) = Branch $ Causal.step go b where
  go b = b { termNamespace = R.insert new r (termNamespace b) }

addPatternName :: Reference -> Int -> Name -> Branch -> Branch
addPatternName r i new (Branch b) = Branch $ Causal.step go b where
  go b = b { patternNamespace = R.insert new (r,i) (patternNamespace b) }

addTypeName :: Reference -> Name -> Branch -> Branch
addTypeName r new (Branch b) = Branch $ Causal.step go b where
  go b = b { typeNamespace = R.insert new r (typeNamespace b) }

renameType :: Name -> Name -> Branch -> Branch
renameType old new (Branch b) =
  Branch $ Causal.stepIf (R.memberDom old . typeNamespace) go b where
    go b = b { typeNamespace = R.replaceDom old new (typeNamespace b)}

renamePattern :: Name -> Name -> Branch -> Branch
renamePattern old new (Branch b) = Branch $ Causal.step go b where
  go b = b { patternNamespace = R.replaceDom old new (patternNamespace b) }

renameTerm :: Name -> Name -> Branch -> Branch
renameTerm old new (Branch b) =
  Branch $ Causal.stepIf (R.memberDom old . termNamespace) go b where
    go b = b { termNamespace = R.replaceDom old new (termNamespace b)}

deleteTermName :: Referent -> Name -> Branch -> Branch
deleteTermName r name (Branch b) = Branch $ Causal.step go b where
  go b = b { termNamespace = R.delete name r (termNamespace b) }

deleteTypeName :: Reference -> Name -> Branch -> Branch
deleteTypeName r name (Branch b) = Branch $ Causal.step go b where
  go b = b { typeNamespace = R.delete name r (typeNamespace b) }

deletePatternName :: Reference -> Int -> Name -> Branch -> Branch
deletePatternName r i name (Branch b) = Branch $ Causal.step go b where
  go b = b { patternNamespace = R.delete name (r, i) (patternNamespace b) }

deleteTermsNamed :: Name -> Branch -> Branch
deleteTermsNamed name (Branch b) = Branch $ Causal.step go b where
  go b = b { termNamespace = R.deleteDom name (termNamespace b) }

deleteTypesNamed :: Name -> Branch -> Branch
deleteTypesNamed name (Branch b) = Branch $ Causal.step go b where
  go b = b { typeNamespace = R.deleteDom name (typeNamespace b) }

deletePatternsNamed :: Name -> Branch -> Branch
deletePatternsNamed name (Branch b) = Branch $ Causal.step go b where
  go b = b { patternNamespace = R.deleteDom name (patternNamespace b) }

toHash :: Branch -> Hash
toHash = Causal.currentHash . unbranch

toNames :: Branch -> Names
toNames b = case head b of
  Branch0 {..} -> Names terms patterns types
   where
    termRefs = Map.fromList $ R.toList termNamespace
    patterns = Map.fromList $ R.toList patternNamespace
    types    = Map.fromList $ R.toList typeNamespace
    terms    = termRefs
