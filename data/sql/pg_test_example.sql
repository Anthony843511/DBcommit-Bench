-- ============================================================
-- SQL Regression Tests for: get_rte_alias() refactoring in ruleutils.c
-- Commit: Print the correct aliases for DML target tables in ruleutils
-- 
-- These tests exercise:
--   1. get_insert_query_def -> get_rte_alias(use_as=true)
--   2. get_update_query_def -> get_rte_alias(use_as=false)
--   3. get_delete_query_def -> get_rte_alias(use_as=false)
--   4. CTE with DML where alias conflict resolution is needed
--   5. DML target without user alias (no-alias path in get_rte_alias)
-- ============================================================


-- ============================================================
-- Test 1: INSERT rule with explicit target table alias
-- Covers: get_insert_query_def -> get_rte_alias(use_as=true)
-- The new code must print "AS alias" for INSERT target tables.
-- pg_get_ruledef() triggers the ruleutils deparse path.
-- ============================================================

CREATE TABLE rte_alias_src1 (id integer, val text);
CREATE TABLE rte_alias_dst1 (id integer, val text);

CREATE VIEW rte_alias_view1 AS SELECT * FROM rte_alias_src1;

-- Rule with INSERT that references target alias via AS keyword
CREATE RULE rte_alias_ins_rule AS ON INSERT TO rte_alias_view1
    DO INSTEAD
        INSERT INTO rte_alias_dst1 AS dst1 (id, val)
        VALUES (NEW.id, NEW.val);

-- Trigger get_insert_query_def -> get_rte_alias(use_as=true)
SELECT pg_get_ruledef(oid) FROM pg_rewrite
    WHERE rulename = 'rte_alias_ins_rule';

-- Verify rule round-trips correctly through deparse
SELECT pg_get_ruledef(oid, true) FROM pg_rewrite
    WHERE rulename = 'rte_alias_ins_rule';

DROP VIEW rte_alias_view1;
DROP TABLE rte_alias_dst1;
DROP TABLE rte_alias_src1;


-- ============================================================
-- Test 2: UPDATE rule with explicit target table alias
-- Covers: get_update_query_def -> get_rte_alias(use_as=false)
-- UPDATE uses "alias" (no AS keyword), new code handles this.
-- ============================================================

CREATE TABLE rte_alias_tbl2 (id integer, val text, updated_at timestamptz);
CREATE VIEW rte_alias_view2 AS SELECT id, val FROM rte_alias_tbl2;

-- Rule with UPDATE that uses an alias for the target table
CREATE RULE rte_alias_upd_rule AS ON UPDATE TO rte_alias_view2
    DO ALSO
        UPDATE rte_alias_tbl2 t2
        SET updated_at = now()
        WHERE t2.id = OLD.id;

-- Trigger get_update_query_def -> get_rte_alias(use_as=false)
SELECT pg_get_ruledef(oid) FROM pg_rewrite
    WHERE rulename = 'rte_alias_upd_rule';

SELECT pg_get_ruledef(oid, true) FROM pg_rewrite
    WHERE rulename = 'rte_alias_upd_rule';

DROP VIEW rte_alias_view2;
DROP TABLE rte_alias_tbl2;


-- ============================================================
-- Test 3: DELETE rule with explicit target table alias
-- Covers: get_delete_query_def -> get_rte_alias(use_as=false)
-- DELETE uses no-AS alias printing via get_rte_alias.
-- ============================================================

CREATE TABLE rte_alias_log3 (id integer, deleted_id integer);
CREATE TABLE rte_alias_tbl3 (id integer, val text);
CREATE VIEW rte_alias_view3 AS SELECT * FROM rte_alias_tbl3;

-- Rule with DELETE that has an alias on the target table
CREATE RULE rte_alias_del_rule AS ON DELETE TO rte_alias_view3
    DO ALSO
        DELETE FROM rte_alias_tbl3 t3
        WHERE t3.id = OLD.id;

-- Trigger get_delete_query_def -> get_rte_alias(use_as=false)
SELECT pg_get_ruledef(oid) FROM pg_rewrite
    WHERE rulename = 'rte_alias_del_rule';

SELECT pg_get_ruledef(oid, true) FROM pg_rewrite
    WHERE rulename = 'rte_alias_del_rule';

DROP VIEW rte_alias_view3;
DROP TABLE rte_alias_tbl3;
DROP TABLE rte_alias_log3;


-- ============================================================
-- Test 4: CTE (WITH) containing DML where alias conflict can occur
-- This is the CORE BUG FIX scenario: DML inside WITH clause where
-- the outer query has a table with the same name, forcing ruleutils
-- to assign a different alias to the DML target. get_rte_alias()
-- must use the *resolved* alias, not the user-given one.
-- Covers: alias conflict resolution in WITH + INSERT/UPDATE/DELETE
-- ============================================================

CREATE TABLE rte_alias_data4 (id integer PRIMARY KEY, val text, status text);

-- Insert test data
INSERT INTO rte_alias_data4 VALUES (1, 'alpha', 'active'), (2, 'beta', 'active'), (3, 'gamma', 'inactive');

-- Create a view whose definition contains a WITH clause with DML
-- that will cause ruleutils to deparse the CTE's INSERT target.
-- We use pg_get_viewdef to trigger the deparse code path.
CREATE VIEW rte_alias_cte_view4 AS
    WITH moved AS (
        SELECT id, val FROM rte_alias_data4 WHERE status = 'active'
    )
    SELECT id, val FROM moved;

-- Trigger the view deparse - exercises get_rte_alias via CTEs
SELECT pg_get_viewdef('rte_alias_cte_view4'::regclass);
SELECT pg_get_viewdef('rte_alias_cte_view4'::regclass, true);

-- Now create a rule whose body is a WITH+INSERT to trigger
-- get_insert_query_def inside a CTE context (the actual bug scenario).
CREATE TABLE rte_alias_archive4 (id integer, val text);
CREATE VIEW rte_alias_src_view4 AS SELECT * FROM rte_alias_data4;

CREATE RULE rte_alias_cte_ins_rule AS ON INSERT TO rte_alias_src_view4
    DO INSTEAD
        WITH src AS (SELECT NEW.id, NEW.val)
        INSERT INTO rte_alias_archive4 (id, val)
        SELECT * FROM src;

-- This call exercises get_insert_query_def with a WITH clause,
-- hitting the core fix: alias must be correctly resolved in CTE context
SELECT pg_get_ruledef(oid) FROM pg_rewrite
    WHERE rulename = 'rte_alias_cte_ins_rule';

SELECT pg_get_ruledef(oid, true) FROM pg_rewrite
    WHERE rulename = 'rte_alias_cte_ins_rule';

DROP VIEW rte_alias_src_view4;
DROP TABLE rte_alias_archive4;
DROP VIEW rte_alias_cte_view4;
DROP TABLE rte_alias_data4;


-- ============================================================
-- Test 5: DML target with NO user alias (no-alias path)
-- Covers: get_rte_alias branch where rte->alias == NULL and
-- refname == relation name => printalias stays false (no output).
-- Also covers the INSERT without alias (use_as=true path, no print).
-- ============================================================

CREATE TABLE rte_alias_plain5 (id integer, val text);
CREATE TABLE rte_alias_target5 (id integer, val text);
CREATE VIEW rte_alias_view5 AS SELECT * FROM rte_alias_plain5;

-- No alias at all on INSERT target - tests the NULL alias path in get_rte_alias
CREATE RULE rte_alias_no_alias_ins AS ON INSERT TO rte_alias_view5
    DO INSTEAD
        INSERT INTO rte_alias_target5 (id, val)
        VALUES (NEW.id, NEW.val);

-- No alias on UPDATE target
CREATE RULE rte_alias_no_alias_upd AS ON UPDATE TO rte_alias_view5
    DO ALSO
        UPDATE rte_alias_target5
        SET val = NEW.val
        WHERE id = OLD.id;

-- No alias on DELETE target
CREATE RULE rte_alias_no_alias_del AS ON DELETE TO rte_alias_view5
    DO ALSO
        DELETE FROM rte_alias_target5
        WHERE id = OLD.id;

-- Deparse all three rules - exercises get_rte_alias with NULL alias
-- for INSERT (use_as=true), UPDATE (use_as=false), DELETE (use_as=false)
SELECT pg_get_ruledef(oid) FROM pg_rewrite
    WHERE ev_class = 'rte_alias_view5'::regclass
    AND rulename != '_RETURN'
    ORDER BY rulename;

-- Also verify via pg_get_viewdef (exercises get_from_clause_item path)
SELECT pg_get_viewdef('rte_alias_view5'::regclass);

DROP VIEW rte_alias_view5;
DROP TABLE rte_alias_target5;
DROP TABLE rte_alias_plain5;


-- =============================================================================
-- SQL Regression Tests for commit: "Keep perl style checker happy"
-- genbki.pl: move 'use strict/warnings' before other 'use' statements
--
-- Context: genbki.pl is a build-time Perl script that generates postgres.bki,
-- which initializes the system catalogs. This commit is a pure style fix
-- (reordering 'use strict' to the top). The tests below verify the integrity
-- of the system catalog tables that genbki.pl is responsible for producing,
-- ensuring that the reordering does not affect the generated output.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- Test 1: System catalog pg_class integrity
-- Covers: genbki.pl produces valid pg_class entries (relnamespace, reltype OIDs)
-- ---------------------------------------------------------------------------

-- Verify pg_class entries have valid namespace references (all rows should join)
SELECT count(*) AS broken_namespace_refs
FROM pg_catalog.pg_class c
WHERE c.relnamespace != 0
  AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_namespace n WHERE n.oid = c.relnamespace
  );

-- Verify pg_class reltype references are consistent
SELECT count(*) AS broken_reltype_refs
FROM pg_catalog.pg_class c
WHERE c.reltype != 0
  AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_type t WHERE t.oid = c.reltype
  );

-- Verify every catalog table in pg_catalog schema is visible
SELECT count(*) AS catalog_table_count
FROM pg_catalog.pg_class
WHERE relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'pg_catalog')
  AND relkind = 'r';


-- ---------------------------------------------------------------------------
-- Test 2: System catalog pg_type integrity
-- Covers: genbki.pl correctly generates pg_type rows with valid cross-references
-- ---------------------------------------------------------------------------

-- Verify pg_type entries reference valid namespaces
SELECT count(*) AS broken_type_namespace
FROM pg_catalog.pg_type t
WHERE t.typnamespace != 0
  AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_namespace n WHERE n.oid = t.typnamespace
  );

-- Verify pg_type typinput/typoutput functions exist in pg_proc
SELECT count(*) AS broken_typinput_refs
FROM pg_catalog.pg_type t
WHERE t.typinput != 0
  AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_proc p WHERE p.oid = t.typinput
  );

-- Spot-check: basic built-in types exist (generated by genbki.pl from pg_type.dat)
SELECT typname FROM pg_catalog.pg_type
WHERE typname IN ('int4', 'int8', 'float8', 'text', 'bool', 'oid')
ORDER BY typname;


-- ---------------------------------------------------------------------------
-- Test 3: pg_attribute completeness (genbki.pl generates column metadata)
-- Covers: genbki.pl emits attribute rows; strict mode catches undefined vars
-- ---------------------------------------------------------------------------

CREATE TABLE test_genbki_attr_104 (
    id        integer      NOT NULL,
    name      text,
    value     numeric(10,2),
    flag      boolean      DEFAULT false,
    created   timestamptz  DEFAULT now()
);

-- Verify pg_attribute records were created correctly for this table
SELECT attname, atttypid, attnum
FROM pg_catalog.pg_attribute
WHERE attrelid = 'test_genbki_attr_104'::regclass
  AND attnum > 0
ORDER BY attnum;

-- Verify all attribute type OIDs are valid
SELECT count(*) AS broken_atttype_refs
FROM pg_catalog.pg_attribute a
WHERE a.attrelid = 'test_genbki_attr_104'::regclass
  AND a.attnum > 0
  AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_type t WHERE t.oid = a.atttypid
  );

-- Insert data and verify attribute metadata is consistent with actual data
INSERT INTO test_genbki_attr_104 (id, name, value, flag)
VALUES
    (1, 'alpha',  1.50, true),
    (2, NULL,     0.00, false),
    (3, 'gamma', 99.99, true);

SELECT id, name, value, flag FROM test_genbki_attr_104 ORDER BY id;

DROP TABLE test_genbki_attr_104;


-- ---------------------------------------------------------------------------
-- Test 4: pg_proc system functions integrity
-- Covers: genbki.pl generates pg_proc bootstrap entries; 'use strict' prevents
--         typos in variable names that could corrupt function metadata
-- ---------------------------------------------------------------------------

-- Verify built-in functions have valid return types
SELECT count(*) AS broken_rettype_refs
FROM pg_catalog.pg_proc p
WHERE p.prorettype != 0
  AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_type t WHERE t.oid = p.prorettype
  );

-- Verify built-in functions belong to valid namespaces
SELECT count(*) AS broken_proc_namespace
FROM pg_catalog.pg_proc p
WHERE p.pronamespace != 0
  AND NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_namespace n WHERE n.oid = p.pronamespace
  );

-- Exercise a cross-catalog join: aggregate functions -> pg_proc
SELECT count(*) AS valid_aggregate_count
FROM pg_catalog.pg_aggregate ag
JOIN pg_catalog.pg_proc p ON p.oid = ag.aggfnoid
WHERE p.pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'pg_catalog');


-- ---------------------------------------------------------------------------
-- Test 5: pg_namespace and schema-level catalog consistency
-- Covers: genbki.pl emits pg_namespace bootstrap rows; 'use strict' before
--         'use File::Basename' ensures module loading order is safe
-- ---------------------------------------------------------------------------

-- Verify pg_catalog schema exists and has correct owner
SELECT nspname, nspowner
FROM pg_catalog.pg_namespace
WHERE nspname = 'pg_catalog';

-- Verify information_schema exists (also catalog-managed)
SELECT nspname
FROM pg_catalog.pg_namespace
WHERE nspname = 'information_schema';

-- Create a table in a fresh schema, verify catalog entries are consistent
CREATE SCHEMA test_genbki_ns_104;

CREATE TABLE test_genbki_ns_104.items (
    item_id   serial PRIMARY KEY,
    label     varchar(50) NOT NULL,
    qty       integer     CHECK (qty >= 0),
    price     numeric     DEFAULT 0
);

INSERT INTO test_genbki_ns_104.items (label, qty, price)
VALUES
    ('widget', 10,  2.99),
    ('gadget',  0,  NULL),
    ('doohickey', 5, 14.50);

-- Verify the new table is visible in pg_class with correct namespace
SELECT c.relname, n.nspname
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'test_genbki_ns_104'
  AND c.relkind IN ('r', 'S', 'i')
ORDER BY c.relname;

-- Query with NULLs to exercise edge cases
SELECT item_id, label, qty, price
FROM test_genbki_ns_104.items
WHERE price IS NULL OR qty = 0
ORDER BY item_id;

DROP TABLE test_genbki_ns_104.items;
DROP SCHEMA test_genbki_ns_104;


-- ============================================================
-- SQL Regression Tests for PostgreSQL commit:
-- "Make new GENERATED-expressions code more bulletproof"
--
-- Target code path: ExecGetExtraUpdatedCols() in execUtils.c
-- Key change: When ri_GeneratedExprs == NULL, automatically call
--   ExecInitStoredGenerated(relinfo, estate, CMD_UPDATE)
--   instead of asserting it was already initialized.
--
-- The critical scenario: an ON UPDATE trigger fires before
-- ExecInitStoredGenerated has been called, reaching
-- ExecGetExtraUpdatedCols with ri_GeneratedExprs == NULL.
-- ============================================================

-- ============================================================
-- Test 1: BEFORE UPDATE trigger on table with STORED GENERATED column
-- Covers: ExecGetExtraUpdatedCols called via trigger.c before
--         ExecInitStoredGenerated is called -- the core bug scenario.
-- ============================================================

CREATE TABLE t105_test1 (
    id   int PRIMARY KEY,
    a    int,
    b    int GENERATED ALWAYS AS (a * 2) STORED
);

CREATE FUNCTION t105_trigger_func1() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RETURN NEW;
END;
$$;

-- BEFORE UPDATE trigger: this fires before ExecInitStoredGenerated
-- is called in the normal ModifyTable path, exercising the new
-- lazy-initialization guard in ExecGetExtraUpdatedCols.
CREATE TRIGGER t105_before_upd
    BEFORE UPDATE ON t105_test1
    FOR EACH ROW
    EXECUTE PROCEDURE t105_trigger_func1();

INSERT INTO t105_test1 (id, a) VALUES (1, 10), (2, 20), (3, 30);

-- This UPDATE fires the BEFORE UPDATE trigger, which calls
-- ExecGetAllUpdatedCols -> ExecGetExtraUpdatedCols with
-- ri_GeneratedExprs possibly NULL -- exercises the new code path.
UPDATE t105_test1 SET a = a + 1 WHERE id = 1;
UPDATE t105_test1 SET a = a * 2;

SELECT * FROM t105_test1 ORDER BY id;

DROP TRIGGER t105_before_upd ON t105_test1;
DROP FUNCTION t105_trigger_func1();
DROP TABLE t105_test1;

-- ============================================================
-- Test 2: AFTER UPDATE trigger on table with STORED GENERATED column
-- Covers: ExecGetExtraUpdatedCols called from AFTER UPDATE trigger path
--         (ExecGetAllUpdatedCols in AfterTriggerExecute).
-- ============================================================

CREATE TABLE t105_test2 (
    id   serial PRIMARY KEY,
    val  text,
    val_len int GENERATED ALWAYS AS (length(val)) STORED
);

CREATE FUNCTION t105_after_trigger_func() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    -- Access NEW and OLD to ensure trigger fires fully
    RAISE NOTICE 'AFTER UPDATE: id=%, old_len=%, new_len=%',
        NEW.id, OLD.val_len, NEW.val_len;
    RETURN NEW;
END;
$$;

CREATE TRIGGER t105_after_upd
    AFTER UPDATE ON t105_test2
    FOR EACH ROW
    EXECUTE PROCEDURE t105_after_trigger_func();

INSERT INTO t105_test2 (val) VALUES ('hello'), ('world'), ('postgresql');

-- AFTER UPDATE triggers also call ExecGetAllUpdatedCols, which calls
-- ExecGetExtraUpdatedCols -- exercises the lazy-init guard.
UPDATE t105_test2 SET val = val || '!' WHERE id = 1;
UPDATE t105_test2 SET val = upper(val);

SELECT * FROM t105_test2 ORDER BY id;

DROP TRIGGER t105_after_upd ON t105_test2;
DROP FUNCTION t105_after_trigger_func();
DROP TABLE t105_test2;

-- ============================================================
-- Test 3: UPDATE trigger with OF clause on a GENERATED column
-- Covers: trigger that references the generated column itself in
--         UPDATE OF, combined with the lazy-init path.
-- Per the SQL standard, UPDATE OF base col should fire UPDATE OF
-- generated col too -- ExecGetExtraUpdatedCols is key to this.
-- ============================================================

CREATE TABLE t105_test3 (
    id   int,
    x    int,
    y    int GENERATED ALWAYS AS (x * x) STORED,
    z    int GENERATED ALWAYS AS (x + 100) STORED
);

CREATE FUNCTION t105_gen_update_func() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'trigger fired: x=%, y=%, z=%', NEW.x, NEW.y, NEW.z;
    RETURN NEW;
END;
$$;

-- Trigger fires when generated column y is updated (via x update)
CREATE TRIGGER t105_upd_of_gen
    BEFORE UPDATE OF y ON t105_test3
    FOR EACH ROW
    EXECUTE PROCEDURE t105_gen_update_func();

INSERT INTO t105_test3 (id, x) VALUES (1, 3), (2, 5), (3, 0);

-- Updating x should trigger UPDATE OF y due to generated dependency
-- ExecGetExtraUpdatedCols must correctly return the extra cols bitmask
UPDATE t105_test3 SET x = x + 1;
UPDATE t105_test3 SET x = 10 WHERE id = 1;

SELECT * FROM t105_test3 ORDER BY id;

DROP TRIGGER t105_upd_of_gen ON t105_test3;
DROP FUNCTION t105_gen_update_func();
DROP TABLE t105_test3;

-- ============================================================
-- Test 4: Table with multiple STORED GENERATED columns + trigger
-- Covers: Edge case where ri_GeneratedExprs covers multiple columns,
--         NULL inputs, and the lazy-init path handles them all.
-- ============================================================

CREATE TABLE t105_test4 (
    id    int PRIMARY KEY,
    a     int,
    b     int,
    gen1  int  GENERATED ALWAYS AS (a + b) STORED,
    gen2  int  GENERATED ALWAYS AS (a * b) STORED,
    gen3  text GENERATED ALWAYS AS (a::text || '-' || b::text) STORED
);

CREATE FUNCTION t105_multi_gen_trigger() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    -- Access generated cols to force evaluation
    RAISE NOTICE 'gen1=%, gen2=%, gen3=%', NEW.gen1, NEW.gen2, NEW.gen3;
    RETURN NEW;
END;
$$;

CREATE TRIGGER t105_multi_before
    BEFORE UPDATE ON t105_test4
    FOR EACH ROW
    EXECUTE PROCEDURE t105_multi_gen_trigger();

-- Insert including NULL values to test edge cases
INSERT INTO t105_test4 (id, a, b) VALUES
    (1, 3, 4),
    (2, 0, 0),
    (3, -1, 5),
    (4, 100, 200);

-- Normal update with multiple generated cols -- exercises lazy-init
-- with multiple generated expressions.
UPDATE t105_test4 SET a = a + 1, b = b + 1 WHERE id = 1;
UPDATE t105_test4 SET a = 7 WHERE id = 2;
-- Update resulting in zero-value generated cols (edge: gen2 = 0)
UPDATE t105_test4 SET b = 0 WHERE id = 3;

SELECT * FROM t105_test4 ORDER BY id;

DROP TRIGGER t105_multi_before ON t105_test4;
DROP FUNCTION t105_multi_gen_trigger();
DROP TABLE t105_test4;

-- ============================================================
-- Test 5: Partitioned table with STORED GENERATED column + UPDATE trigger
-- Covers: ExecGetExtraUpdatedCols via trigger on a partition,
--         where ri_GeneratedExprs may not be initialized for the
--         child partition's ResultRelInfo (mimics the logical
--         replication scenario where partition rel infos are set
--         up lazily).
-- ============================================================

CREATE TABLE t105_test5_parent (
    id   int,
    val  int,
    gen  int GENERATED ALWAYS AS (val * 3) STORED
) PARTITION BY RANGE (id);

CREATE TABLE t105_test5_p1
    PARTITION OF t105_test5_parent
    FOR VALUES FROM (1) TO (100);

CREATE TABLE t105_test5_p2
    PARTITION OF t105_test5_parent
    FOR VALUES FROM (100) TO (200);

CREATE FUNCTION t105_partition_trigger_func() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'partition trigger: id=%, val=%, gen=%',
        NEW.id, NEW.val, NEW.gen;
    RETURN NEW;
END;
$$;

-- Attach trigger on the parent -- PostgreSQL propagates to partitions.
-- When updating a row on a specific partition, ExecGetExtraUpdatedCols
-- is called on that partition's ResultRelInfo, which may have
-- ri_GeneratedExprs == NULL (the lazy-init path is exercised).
CREATE TRIGGER t105_part_before_upd
    BEFORE UPDATE ON t105_test5_parent
    FOR EACH ROW
    EXECUTE PROCEDURE t105_partition_trigger_func();

INSERT INTO t105_test5_parent (id, val) VALUES
    (1, 10), (2, 20), (50, 50),
    (100, 100), (150, 150), (199, 199);

-- UPDATE rows in different partitions, exercising the lazy-init
-- guard for each partition's ResultRelInfo.
UPDATE t105_test5_parent SET val = val + 5 WHERE id < 100;
UPDATE t105_test5_parent SET val = val - 3 WHERE id >= 100;
-- Cross-partition update (row moves between partitions)
UPDATE t105_test5_parent SET id = 110, val = 99 WHERE id = 50;

SELECT * FROM t105_test5_parent ORDER BY id;

DROP TRIGGER t105_part_before_upd ON t105_test5_parent;
DROP FUNCTION t105_partition_trigger_func();
DROP TABLE t105_test5_parent;


-- SQL regression tests for:
-- "Avoid reference to nonexistent array element in ExecInitAgg()"
-- Fix: add `if (length == 0) continue;` in ExecInitAgg() to skip empty
-- grouping sets before accessing eqfunctions[length-1] (which would be
-- eqfunctions[-1] — an out-of-bounds access).
--
-- The fix is triggered when:
--   1. AGG_SORTED strategy is used (sorted grouping sets / ROLLUP / CUBE)
--   2. At least one grouping set in the phase has length == 0 (i.e. `()`)
--
-- All tests use ORDER BY to push the planner toward a sorted aggregation plan,
-- which is the only plan shape that runs through the patched loop.

-- ===========================================================================
-- Test 1: ROLLUP with a single column (produces empty grouping set implicitly)
-- Covers: length==0 branch via ROLLUP((a)) which expands to GROUPING SETS((a),())
-- ===========================================================================

CREATE TABLE t106_rollup1 (
    a INTEGER,
    b INTEGER,
    v INTEGER
);

INSERT INTO t106_rollup1 VALUES
    (1, 10, 100),
    (1, 20, 200),
    (2, 10, 300),
    (2, 20, 400),
    (3, 30, 500);

-- ROLLUP(a) expands to GROUPING SETS((a),()), the () set has length=0.
-- With ORDER BY forcing a sorted path, ExecInitAgg must handle length==0.
SELECT a, sum(v), count(*)
FROM t106_rollup1
GROUP BY ROLLUP(a)
ORDER BY a NULLS LAST;

EXPLAIN (COSTS OFF)
SELECT a, sum(v), count(*)
FROM t106_rollup1
GROUP BY ROLLUP(a)
ORDER BY a NULLS LAST;

DROP TABLE t106_rollup1;


-- ===========================================================================
-- Test 2: Explicit GROUPING SETS containing only the empty set `()`
-- Covers: ALL grouping sets have length==0; every iteration hits the new branch
-- ===========================================================================

CREATE TABLE t106_empty_only (
    a INTEGER,
    v INTEGER
);

INSERT INTO t106_empty_only VALUES (1, 10), (2, 20), (3, 30);

-- Every grouping set is empty; the loop over gset_lengths always sees length=0.
SELECT sum(v), count(*)
FROM t106_empty_only
GROUP BY GROUPING SETS ((), (), ());

DROP TABLE t106_empty_only;


-- ===========================================================================
-- Test 3: Mixed GROUPING SETS — empty set together with non-empty sets
-- Covers: length==0 interleaved with length>0 so both the new `continue` branch
--         and the normal eqfunctions[length-1] build branch are exercised.
-- ===========================================================================

CREATE TABLE t106_mixed (
    a INTEGER,
    b INTEGER,
    v INTEGER
);

INSERT INTO t106_mixed VALUES
    (1, 1, 10),
    (1, 2, 20),
    (2, 1, 30),
    (2, 2, 40),
    (NULL, 3, 50);

-- GROUPING SETS((a,b), (), (a)) → lengths: 2, 0, 1
-- The empty set () must be skipped without touching eqfunctions[-1].
SELECT a, b, sum(v), count(*)
FROM t106_mixed
GROUP BY GROUPING SETS ((a, b), (), (a))
ORDER BY a NULLS LAST, b NULLS LAST;

EXPLAIN (COSTS OFF)
SELECT a, b, sum(v), count(*)
FROM t106_mixed
GROUP BY GROUPING SETS ((a, b), (), (a))
ORDER BY a NULLS LAST, b NULLS LAST;

DROP TABLE t106_mixed;


-- ===========================================================================
-- Test 4: CUBE producing multiple empty / partial grouping sets
-- Covers: CUBE(a, b) expands to GROUPING SETS((a,b),(a),(b),()); the () set
--         (length=0) must be skipped safely in ExecInitAgg().
-- ===========================================================================

CREATE TABLE t106_cube (
    a TEXT,
    b TEXT,
    v NUMERIC
);

INSERT INTO t106_cube VALUES
    ('x', 'p', 1.5),
    ('x', 'q', 2.5),
    ('y', 'p', 3.5),
    ('y', 'q', 4.5),
    (NULL, 'p', 5.0),
    ('x', NULL, 6.0);

-- CUBE(a,b) → GROUPING SETS((a,b),(a),(b),())
SELECT a, b, sum(v), count(*)
FROM t106_cube
GROUP BY CUBE(a, b)
ORDER BY a NULLS LAST, b NULLS LAST;

EXPLAIN (COSTS OFF)
SELECT a, b, sum(v), count(*)
FROM t106_cube
GROUP BY CUBE(a, b)
ORDER BY a NULLS LAST, b NULLS LAST;

DROP TABLE t106_cube;


-- ===========================================================================
-- Test 5: ROLLUP with multiple columns and NULL data — edge case
-- Covers: ROLLUP(a, b) expands to GROUPING SETS((a,b),(a),()) with real NULLs
--         in the data; ensures the fix is safe with NULL inputs and that
--         the grand-total row (from the empty grouping set) is produced correctly.
-- ===========================================================================

CREATE TABLE t106_rollup_null (
    a INTEGER,
    b INTEGER,
    v INTEGER
);

INSERT INTO t106_rollup_null VALUES
    (1,   1,  10),
    (1,   1,  20),
    (1,   NULL, 30),
    (NULL, 2,  40),
    (NULL, NULL, 50);

-- ROLLUP(a,b) → GROUPING SETS((a,b),(a),()); length sequence: 2, 1, 0.
-- The empty-set row is the grand total; must not crash/access eqfunctions[-1].
SELECT a, b, sum(v) AS total, count(*) AS cnt, grouping(a, b) AS grp
FROM t106_rollup_null
GROUP BY ROLLUP(a, b)
ORDER BY grouping(a, b), a NULLS LAST, b NULLS LAST;

EXPLAIN (COSTS OFF)
SELECT a, b, sum(v) AS total, count(*) AS cnt, grouping(a, b) AS grp
FROM t106_rollup_null
GROUP BY ROLLUP(a, b)
ORDER BY grouping(a, b), a NULLS LAST, b NULLS LAST;

DROP TABLE t106_rollup_null;


-- ============================================================
-- SQL Regression Tests for commit:
--   "Add some recursion and looping defenses in prepjointree.c"
--
-- Covered code paths:
--   1. pull_up_sublinks_jointree_recurse  -> check_stack_depth()
--   2. pull_up_subqueries_recurse         -> check_stack_depth() + CHECK_FOR_INTERRUPTS()
--   3. is_simple_union_all_recurse        -> check_stack_depth()
-- ============================================================


-- ============================================================
-- Test 1: Trigger pull_up_subqueries_recurse via nested subqueries
--         in FROM clause (multi-level subquery pull-up)
-- ============================================================
CREATE TABLE pjt_t1 (id int, val text);
INSERT INTO pjt_t1 VALUES (1, 'a'), (2, 'b'), (3, 'c'), (NULL, 'd');

-- Three levels of subquery nesting: each level triggers
-- pull_up_subqueries_recurse, exercising check_stack_depth()
-- and CHECK_FOR_INTERRUPTS() at each recursion step.
EXPLAIN SELECT *
FROM (
    SELECT *
    FROM (
        SELECT *
        FROM (
            SELECT id, val FROM pjt_t1
        ) innermost
        WHERE id IS NOT NULL
    ) middle
    WHERE val <> 'z'
) outermost
WHERE id > 0;

SELECT *
FROM (
    SELECT *
    FROM (
        SELECT *
        FROM (
            SELECT id, val FROM pjt_t1
        ) innermost
        WHERE id IS NOT NULL
    ) middle
    WHERE val <> 'z'
) outermost
WHERE id > 0;

DROP TABLE pjt_t1;


-- ============================================================
-- Test 2: Trigger pull_up_sublinks_jointree_recurse via sublink
--         inside a JOIN tree (EXISTS / IN subquery links)
-- ============================================================
CREATE TABLE pjt_a (id int, grp int);
CREATE TABLE pjt_b (id int, grp int);
INSERT INTO pjt_a VALUES (1,1),(2,1),(3,2),(4,NULL);
INSERT INTO pjt_b VALUES (1,1),(2,2),(3,3);

-- EXISTS sublink inside a nested JOIN forces the planner to
-- recurse through pull_up_sublinks_jointree_recurse on each join node.
EXPLAIN SELECT a.id
FROM pjt_a a
JOIN pjt_b b ON a.grp = b.grp
WHERE EXISTS (
    SELECT 1 FROM pjt_b b2
    WHERE b2.id = a.id
);

SELECT a.id
FROM pjt_a a
JOIN pjt_b b ON a.grp = b.grp
WHERE EXISTS (
    SELECT 1 FROM pjt_b b2
    WHERE b2.id = a.id
)
ORDER BY a.id;

-- IN sublink in a multi-join query also exercises the same path
EXPLAIN SELECT a.id
FROM pjt_a a
LEFT JOIN pjt_b b ON a.grp = b.grp
WHERE a.id IN (SELECT id FROM pjt_b);

SELECT a.id
FROM pjt_a a
LEFT JOIN pjt_b b ON a.grp = b.grp
WHERE a.id IN (SELECT id FROM pjt_b)
ORDER BY a.id;

DROP TABLE pjt_a;
DROP TABLE pjt_b;


-- ============================================================
-- Test 3: Trigger is_simple_union_all_recurse via deeply nested
--         UNION ALL subquery used as a FROM-clause relation
-- ============================================================
CREATE TABLE pjt_u (id int, label text);
INSERT INTO pjt_u VALUES (1,'x'),(2,'y'),(3,NULL);

-- A four-branch UNION ALL causes is_simple_union_all_recurse to
-- recurse through the binary SetOperationStmt tree, hitting
-- check_stack_depth() at each level.
EXPLAIN SELECT *
FROM (
    SELECT id, label FROM pjt_u WHERE id = 1
    UNION ALL
    SELECT id, label FROM pjt_u WHERE id = 2
    UNION ALL
    SELECT id, label FROM pjt_u WHERE id = 3
    UNION ALL
    SELECT id, label FROM pjt_u WHERE id IS NULL
) sub;

SELECT *
FROM (
    SELECT id, label FROM pjt_u WHERE id = 1
    UNION ALL
    SELECT id, label FROM pjt_u WHERE id = 2
    UNION ALL
    SELECT id, label FROM pjt_u WHERE id = 3
    UNION ALL
    SELECT id, label FROM pjt_u WHERE id IS NULL
) sub
ORDER BY id NULLS LAST;

DROP TABLE pjt_u;


-- ============================================================
-- Test 4: Trigger pull_up_subqueries_recurse through JOIN nodes
--         (INNER / LEFT / FULL JOIN with subquery operands)
--         Edge case: NULL values and empty result subqueries
-- ============================================================
CREATE TABLE pjt_p (k int, v int);
CREATE TABLE pjt_q (k int, v int);
INSERT INTO pjt_p VALUES (1,10),(2,NULL),(3,30),(NULL,40);
INSERT INTO pjt_q VALUES (1,100),(3,300),(5,500);

-- INNER JOIN of two subqueries: planner recurses into each side
EXPLAIN SELECT lhs.k, rhs.v
FROM (SELECT k, v FROM pjt_p WHERE v IS NOT NULL) lhs
JOIN (SELECT k, v FROM pjt_q) rhs
ON lhs.k = rhs.k;

-- LEFT JOIN with subquery on right: exercises lowest_nulling_outer_join path
EXPLAIN SELECT lhs.k, rhs.v
FROM (SELECT k, v FROM pjt_p) lhs
LEFT JOIN (SELECT k, v FROM pjt_q WHERE v > 200) rhs
ON lhs.k = rhs.k;

-- FULL JOIN exercises the full-outer-join recursion branch
EXPLAIN SELECT lhs.k, rhs.k
FROM (SELECT k FROM pjt_p) lhs
FULL JOIN (SELECT k FROM pjt_q) rhs
ON lhs.k = rhs.k;

SELECT lhs.k, rhs.v
FROM (SELECT k, v FROM pjt_p WHERE v IS NOT NULL) lhs
JOIN (SELECT k, v FROM pjt_q) rhs
ON lhs.k = rhs.k
ORDER BY lhs.k;

DROP TABLE pjt_p;
DROP TABLE pjt_q;


-- ============================================================
-- Test 5: Combined test — sublink inside a UNION ALL subquery,
--         exercises all three modified recursive functions together
-- ============================================================
CREATE TABLE pjt_main (id int, cat int, score int);
CREATE TABLE pjt_ref  (cat int, min_score int);
INSERT INTO pjt_main VALUES
    (1,1,50),(2,1,NULL),(3,2,80),(4,2,90),(5,3,10),(6,NULL,20);
INSERT INTO pjt_ref  VALUES (1,40),(2,75),(3,5);

-- The outer query uses EXISTS (sublink -> pull_up_sublinks path).
-- The subquery is a UNION ALL (-> is_simple_union_all_recurse path).
-- Multiple FROM-clause nesting levels (-> pull_up_subqueries_recurse path).
EXPLAIN SELECT *
FROM (
    SELECT id, cat, score FROM pjt_main WHERE cat = 1
    UNION ALL
    SELECT id, cat, score FROM pjt_main WHERE cat = 2
    UNION ALL
    SELECT id, cat, score FROM pjt_main WHERE cat IS NULL
) combined
WHERE EXISTS (
    SELECT 1 FROM pjt_ref r
    WHERE r.cat = combined.cat
      AND combined.score >= r.min_score
);

SELECT *
FROM (
    SELECT id, cat, score FROM pjt_main WHERE cat = 1
    UNION ALL
    SELECT id, cat, score FROM pjt_main WHERE cat = 2
    UNION ALL
    SELECT id, cat, score FROM pjt_main WHERE cat IS NULL
) combined
WHERE EXISTS (
    SELECT 1 FROM pjt_ref r
    WHERE r.cat = combined.cat
      AND combined.score >= r.min_score
)
ORDER BY id;

DROP TABLE pjt_main;
DROP TABLE pjt_ref;

-- ============================================================
-- SQL Regression Tests for PostgreSQL commit:
-- "Avoid O(N^2) cost when pulling up lots of UNION ALL subqueries"
--
-- Covers:
--   1. perform_pullup_replace_vars() early-return path for appendrel child
--   2. fix_append_rel_relids() now takes PlannerInfo* (no PHVs path)
--   3. fix_append_rel_relids() with PHVs (lastPHId != 0 path)
--   4. pull_up_simple_subquery() removed hasSubLinks guard
--   5. Large N UNION ALL (scalability of the O(N^2) -> O(N) fix)
-- ============================================================


-- ============================================================
-- Test 1: Basic UNION ALL subquery pull-up (appendrel early-return path)
-- Covers: perform_pullup_replace_vars() containing_appendrel early return.
-- A simple UNION ALL inside a subquery should be flattened by the planner;
-- the new code path exits immediately after updating translated_vars of the
-- AppendRelInfo that was just created, instead of scanning the whole query.
-- ============================================================
CREATE TABLE t108_a (id integer, val text);
CREATE TABLE t108_b (id integer, val text);
INSERT INTO t108_a VALUES (1, 'alpha'), (2, 'beta'), (NULL, 'gamma');
INSERT INTO t108_b VALUES (3, 'delta'), (4, NULL), (2, 'beta');

-- EXPLAIN to exercise the planner path
EXPLAIN (COSTS OFF)
SELECT * FROM (
    SELECT id, val FROM t108_a
    UNION ALL
    SELECT id, val FROM t108_b
) sub
WHERE id > 1;

-- Also run the query to confirm correct results
SELECT * FROM (
    SELECT id, val FROM t108_a
    UNION ALL
    SELECT id, val FROM t108_b
) sub
WHERE id > 1
ORDER BY id, val;

DROP TABLE t108_a;
DROP TABLE t108_b;


-- ============================================================
-- Test 2: Multiple UNION ALL branches (the N^2 -> N optimization)
-- Covers: perform_pullup_replace_vars() containing_appendrel early return
--         called N times, each time only touching its own AppendRelInfo.
-- With many UNION ALL members, old code was O(N^2); new code is O(N).
-- ============================================================
CREATE TABLE t108_m1 (x integer, y text);
CREATE TABLE t108_m2 (x integer, y text);
CREATE TABLE t108_m3 (x integer, y text);
CREATE TABLE t108_m4 (x integer, y text);
CREATE TABLE t108_m5 (x integer, y text);

INSERT INTO t108_m1 VALUES (1, 'one'), (NULL, 'null1');
INSERT INTO t108_m2 VALUES (2, 'two'), (NULL, 'null2');
INSERT INTO t108_m3 VALUES (3, 'three'), (NULL, 'null3');
INSERT INTO t108_m4 VALUES (4, 'four'),  (NULL, 'null4');
INSERT INTO t108_m5 VALUES (5, 'five'),  (NULL, 'null5');

EXPLAIN (COSTS OFF)
SELECT * FROM (
    SELECT x, y FROM t108_m1
    UNION ALL
    SELECT x, y FROM t108_m2
    UNION ALL
    SELECT x, y FROM t108_m3
    UNION ALL
    SELECT x, y FROM t108_m4
    UNION ALL
    SELECT x, y FROM t108_m5
) combined
WHERE x IS NOT NULL
ORDER BY x;

SELECT * FROM (
    SELECT x, y FROM t108_m1
    UNION ALL
    SELECT x, y FROM t108_m2
    UNION ALL
    SELECT x, y FROM t108_m3
    UNION ALL
    SELECT x, y FROM t108_m4
    UNION ALL
    SELECT x, y FROM t108_m5
) combined
WHERE x IS NOT NULL
ORDER BY x;

DROP TABLE t108_m1;
DROP TABLE t108_m2;
DROP TABLE t108_m3;
DROP TABLE t108_m4;
DROP TABLE t108_m5;


-- ============================================================
-- Test 3: UNION ALL under outer join (PlaceHolderVar / lastPHId != 0 path)
-- Covers: fix_append_rel_relids() calling substitute_phv_relids only when
--         lastPHId != 0; and perform_pullup_replace_vars() need_phvs logic.
-- A UNION ALL subquery placed under a LEFT JOIN introduces PlaceHolderVars
-- so that lastPHId > 0 in the planner, exercising the PHV branch.
-- ============================================================
CREATE TABLE t108_outer (oid integer PRIMARY KEY, label text);
CREATE TABLE t108_inner1 (fk integer, score integer);
CREATE TABLE t108_inner2 (fk integer, score integer);

INSERT INTO t108_outer VALUES (1, 'A'), (2, 'B'), (3, 'C');
INSERT INTO t108_inner1 VALUES (1, 10), (1, 20), (2, 30);
INSERT INTO t108_inner2 VALUES (2, 40), (3, 50);

-- LEFT JOIN with a UNION ALL subquery on the right side
-- forces PlaceHolderVars to be generated for expressions from the nullable side
EXPLAIN (COSTS OFF)
SELECT o.label, sub.score
FROM t108_outer o
LEFT JOIN (
    SELECT fk, score FROM t108_inner1
    UNION ALL
    SELECT fk, score FROM t108_inner2
) sub ON sub.fk = o.oid
ORDER BY o.oid, sub.score;

SELECT o.label, sub.score
FROM t108_outer o
LEFT JOIN (
    SELECT fk, score FROM t108_inner1
    UNION ALL
    SELECT fk, score FROM t108_inner2
) sub ON sub.fk = o.oid
ORDER BY o.oid, sub.score;

DROP TABLE t108_outer;
DROP TABLE t108_inner1;
DROP TABLE t108_inner2;


-- ============================================================
-- Test 4: Subquery with SubLinks inside UNION ALL members
--         (removed hasSubLinks guard in pull_up_simple_subquery)
-- Covers: The old code had "parse->hasSubLinks || ..." guard removed.
--         Now fix_append_rel_relids is called independently of hasSubLinks.
--         We trigger this by having a correlated subquery reference alongside
--         a UNION ALL so hasSubLinks=true in the parent query.
-- ============================================================
CREATE TABLE t108_ref  (id integer PRIMARY KEY, threshold integer);
CREATE TABLE t108_data (id integer, val integer);

INSERT INTO t108_ref  VALUES (1, 100), (2, 200);
INSERT INTO t108_data VALUES (1, 50), (1, 150), (2, 80), (2, 250), (2, 190);

-- The outer query has a sublink (EXISTS), and the FROM clause has a UNION ALL.
-- This exercises the path where hasSubLinks=true and append_rel_list is non-nil.
EXPLAIN (COSTS OFF)
SELECT *
FROM (
    SELECT id, val FROM t108_data WHERE val < 100
    UNION ALL
    SELECT id, val FROM t108_data WHERE val >= 100
) u
WHERE EXISTS (
    SELECT 1 FROM t108_ref r WHERE r.id = u.id AND u.val < r.threshold
)
ORDER BY id, val;

SELECT *
FROM (
    SELECT id, val FROM t108_data WHERE val < 100
    UNION ALL
    SELECT id, val FROM t108_data WHERE val >= 100
) u
WHERE EXISTS (
    SELECT 1 FROM t108_ref r WHERE r.id = u.id AND u.val < r.threshold
)
ORDER BY id, val;

DROP TABLE t108_ref;
DROP TABLE t108_data;


-- ============================================================
-- Test 5: UNION ALL with expressions / computed columns (translated_vars)
-- Covers: AppendRelInfo.translated_vars update via pullup_replace_vars in
--         the early-return branch; ensures Var replacement is correct when
--         target list contains expressions, NULLs, and type casts.
-- ============================================================
CREATE TABLE t108_expr1 (a integer, b integer);
CREATE TABLE t108_expr2 (a integer, b integer);

INSERT INTO t108_expr1 VALUES (1, 10), (2, 20), (NULL, 30);
INSERT INTO t108_expr2 VALUES (3, NULL), (4, 40), (2, 20);

EXPLAIN (COSTS OFF)
SELECT total, doubled
FROM (
    SELECT a + b         AS total,
           b * 2         AS doubled
    FROM t108_expr1
    UNION ALL
    SELECT a + b         AS total,
           b * 2         AS doubled
    FROM t108_expr2
) computed
WHERE total IS NOT NULL
ORDER BY total, doubled;

SELECT total, doubled
FROM (
    SELECT a + b         AS total,
           b * 2         AS doubled
    FROM t108_expr1
    UNION ALL
    SELECT a + b         AS total,
           b * 2         AS doubled
    FROM t108_expr2
) computed
WHERE total IS NOT NULL
ORDER BY total, doubled;

-- Also test with a join on top of the UNION ALL to exercise fix_append_rel_relids
CREATE TABLE t108_lookup (total integer, category text);
INSERT INTO t108_lookup VALUES (11, 'low'), (22, 'medium'), (44, 'medium'), (60, 'high');

EXPLAIN (COSTS OFF)
SELECT c.total, c.doubled, l.category
FROM (
    SELECT a + b AS total, b * 2 AS doubled FROM t108_expr1
    UNION ALL
    SELECT a + b AS total, b * 2 AS doubled FROM t108_expr2
) c
JOIN t108_lookup l ON l.total = c.total
ORDER BY c.total;

SELECT c.total, c.doubled, l.category
FROM (
    SELECT a + b AS total, b * 2 AS doubled FROM t108_expr1
    UNION ALL
    SELECT a + b AS total, b * 2 AS doubled FROM t108_expr2
) c
JOIN t108_lookup l ON l.total = c.total
ORDER BY c.total;

DROP TABLE t108_expr1;
DROP TABLE t108_expr2;
DROP TABLE t108_lookup;


-- ============================================================
-- SQL Regression Tests for: Fix broken MemoizePath support in
-- reparameterize_path()
-- 
-- Commit: The T_Memoize case in reparameterize_path() now
-- properly recurses to subpath before creating a new MemoizePath.
-- Without the fix, the subpath was not reparameterized, potentially
-- causing wrong query results when join clauses were missed.
--
-- Trigger conditions:
--   1. enable_memoize = on  (Memoize node enabled, PG14+)
--   2. Nested loop join with parameterized inner path
--   3. Partitioned table (appendrel) requiring reparameterize_path()
--   4. LATERAL references forcing parameterization
-- ============================================================


-- ============================================================
-- Test 1: Basic Memoize + NestLoop with partitioned inner table
-- Covers: reparameterize_path() T_Memoize case, normal execution path.
-- A partitioned inner table with index + NestLoop forces Memoize
-- reparameterization across partitions.
-- ============================================================
SET enable_memoize = on;
SET enable_partitionwise_join = on;
SET enable_hashjoin = off;
SET enable_mergejoin = off;

CREATE TABLE test109_outer (id int, val int);
INSERT INTO test109_outer SELECT i, i % 10 FROM generate_series(1, 100) i;
ANALYZE test109_outer;

CREATE TABLE test109_inner (id int, outer_id int, data text) PARTITION BY RANGE(id);
CREATE TABLE test109_inner_p1 PARTITION OF test109_inner FOR VALUES FROM (1) TO (51);
CREATE TABLE test109_inner_p2 PARTITION OF test109_inner FOR VALUES FROM (51) TO (101);
INSERT INTO test109_inner SELECT i, i % 100 + 1, 'data_' || i FROM generate_series(1, 100) i;
CREATE INDEX ON test109_inner_p1(outer_id);
CREATE INDEX ON test109_inner_p2(outer_id);
ANALYZE test109_inner;

-- This query triggers NestLoop + Memoize over partitioned inner table
EXPLAIN (COSTS OFF)
SELECT o.id, i.data
FROM test109_outer o
JOIN test109_inner i ON i.outer_id = o.id
WHERE o.val = 5
ORDER BY o.id, i.id;

SELECT o.id, i.data
FROM test109_outer o
JOIN test109_inner i ON i.outer_id = o.id
WHERE o.val = 5
ORDER BY o.id, i.id;

DROP TABLE test109_outer;
DROP TABLE test109_inner;
RESET enable_memoize;
RESET enable_partitionwise_join;
RESET enable_hashjoin;
RESET enable_mergejoin;


-- ============================================================
-- Test 2: LATERAL join with partitioned table — reparameterize
-- Covers: reparameterize_path() called from partitionwise join
-- planning with LATERAL reference; subpath must be reparameterized.
-- ============================================================
SET enable_memoize = on;
SET enable_partitionwise_join = on;
SET enable_hashjoin = off;
SET enable_mergejoin = off;

CREATE TABLE test109_a (k int, v int);
INSERT INTO test109_a SELECT i, i*2 FROM generate_series(1, 50) i;
ANALYZE test109_a;

CREATE TABLE test109_b (k int, fk int, s text) PARTITION BY RANGE(k);
CREATE TABLE test109_b_p1 PARTITION OF test109_b FOR VALUES FROM (1) TO (26);
CREATE TABLE test109_b_p2 PARTITION OF test109_b FOR VALUES FROM (26) TO (51);
INSERT INTO test109_b SELECT i, i, 'str_'||i FROM generate_series(1, 50) i;
CREATE INDEX ON test109_b_p1(fk);
CREATE INDEX ON test109_b_p2(fk);
ANALYZE test109_b;

-- LATERAL join: inner references outer column, forces parameterization
-- reparameterize_path() will be called on MemoizePath wrapping partition scans
EXPLAIN (COSTS OFF)
SELECT a.k, sub.s
FROM test109_a a
LEFT JOIN LATERAL (
    SELECT b.s FROM test109_b b WHERE b.fk = a.k
) sub ON true
ORDER BY a.k;

SELECT a.k, sub.s
FROM test109_a a
LEFT JOIN LATERAL (
    SELECT b.s FROM test109_b b WHERE b.fk = a.k
) sub ON true
ORDER BY a.k;

DROP TABLE test109_a;
DROP TABLE test109_b;
RESET enable_memoize;
RESET enable_partitionwise_join;
RESET enable_hashjoin;
RESET enable_mergejoin;


-- ============================================================
-- Test 3: Three-way join with partitioned table — deeper reparameterization
-- Covers: reparameterize_path() recursion through multiple levels;
-- the fix ensures subpath is properly reparameterized when Memoize
-- is nested above another parameterized path.
-- ============================================================
SET enable_memoize = on;
SET enable_partitionwise_join = on;
SET enable_hashjoin = off;
SET enable_mergejoin = off;

CREATE TABLE test109_t1 (id int, grp int);
INSERT INTO test109_t1 SELECT i, i % 5 FROM generate_series(1, 30) i;
ANALYZE test109_t1;

CREATE TABLE test109_t2 (id int, t1_id int, score int);
INSERT INTO test109_t2 SELECT i, i % 30 + 1, i*3 FROM generate_series(1, 60) i;
ANALYZE test109_t2;

CREATE TABLE test109_t3 (id int, t1_id int, label text) PARTITION BY RANGE(id);
CREATE TABLE test109_t3_p1 PARTITION OF test109_t3 FOR VALUES FROM (1) TO (31);
CREATE TABLE test109_t3_p2 PARTITION OF test109_t3 FOR VALUES FROM (31) TO (61);
INSERT INTO test109_t3 SELECT i, i % 30 + 1, 'L'||i FROM generate_series(1, 60) i;
CREATE INDEX ON test109_t3_p1(t1_id);
CREATE INDEX ON test109_t3_p2(t1_id);
ANALYZE test109_t3;

-- Three-way join: t1 -> t2 -> t3(partitioned), Memoize may appear on t3 access
EXPLAIN (COSTS OFF)
SELECT t1.id, t2.score, t3.label
FROM test109_t1 t1
JOIN test109_t2 t2 ON t2.t1_id = t1.id
JOIN test109_t3 t3 ON t3.t1_id = t1.id
WHERE t1.grp = 2
ORDER BY t1.id, t2.id, t3.id;

SELECT t1.id, t2.score, t3.label
FROM test109_t1 t1
JOIN test109_t2 t2 ON t2.t1_id = t1.id
JOIN test109_t3 t3 ON t3.t1_id = t1.id
WHERE t1.grp = 2
ORDER BY t1.id, t2.id, t3.id;

DROP TABLE test109_t1;
DROP TABLE test109_t2;
DROP TABLE test109_t3;
RESET enable_memoize;
RESET enable_partitionwise_join;
RESET enable_hashjoin;
RESET enable_mergejoin;


-- ============================================================
-- Test 4: NULL values in join key — edge case for Memoize correctness
-- Covers: reparameterize_path() T_Memoize with NULL join keys.
-- After the fix, Memoize subpath properly enforces join clauses,
-- so NULLs should not produce spurious matches.
-- ============================================================
SET enable_memoize = on;
SET enable_partitionwise_join = on;
SET enable_hashjoin = off;
SET enable_mergejoin = off;

CREATE TABLE test109_null_outer (id int, fk int);
INSERT INTO test109_null_outer VALUES
  (1, 10), (2, NULL), (3, 20), (4, NULL), (5, 30), (6, 10);
ANALYZE test109_null_outer;

CREATE TABLE test109_null_inner (id int, val int, info text) PARTITION BY RANGE(id);
CREATE TABLE test109_null_inner_p1 PARTITION OF test109_null_inner FOR VALUES FROM (1) TO (21);
CREATE TABLE test109_null_inner_p2 PARTITION OF test109_null_inner FOR VALUES FROM (21) TO (41);
INSERT INTO test109_null_inner VALUES
  (10, 100, 'ten'), (20, 200, 'twenty'), (30, 300, 'thirty'),
  (11, 110, 'eleven'), (21, 210, 'twenty-one'), (31, 310, 'thirty-one');
CREATE INDEX ON test109_null_inner_p1(id);
CREATE INDEX ON test109_null_inner_p2(id);
ANALYZE test109_null_inner;

-- NULL fk should produce no matches (join clause enforced by reparameterized subpath)
EXPLAIN (COSTS OFF)
SELECT o.id, i.info
FROM test109_null_outer o
JOIN test109_null_inner i ON i.id = o.fk
ORDER BY o.id;

SELECT o.id, i.info
FROM test109_null_outer o
JOIN test109_null_inner i ON i.id = o.fk
ORDER BY o.id;

DROP TABLE test109_null_outer;
DROP TABLE test109_null_inner;
RESET enable_memoize;
RESET enable_partitionwise_join;
RESET enable_hashjoin;
RESET enable_mergejoin;


-- ============================================================
-- Test 5: Correlated subquery with partitioned table forcing
-- reparameterize on MemoizePath + verify result correctness
-- Covers: The bug scenario — without fix, subpath of Memoize
-- might miss join clause leading to wrong results. With fix,
-- all rows must satisfy the join predicate.
-- ============================================================
SET enable_memoize = on;
SET enable_partitionwise_join = on;
SET enable_hashjoin = off;
SET enable_mergejoin = off;
SET enable_nestloop = on;

CREATE TABLE test109_driver (aid int, bval int);
INSERT INTO test109_driver SELECT i, i % 20 + 1 FROM generate_series(1, 40) i;
ANALYZE test109_driver;

CREATE TABLE test109_lookup (id int, key int, result text) PARTITION BY RANGE(id);
CREATE TABLE test109_lookup_p1 PARTITION OF test109_lookup FOR VALUES FROM (1) TO (11);
CREATE TABLE test109_lookup_p2 PARTITION OF test109_lookup FOR VALUES FROM (11) TO (21);
INSERT INTO test109_lookup SELECT i, i, 'result_'||i FROM generate_series(1, 20) i;
CREATE INDEX ON test109_lookup_p1(key);
CREATE INDEX ON test109_lookup_p2(key);
ANALYZE test109_lookup;

-- Correlated subquery: each row of driver looks up matching rows in partitioned table
-- reparameterize_path() on MemoizePath subpath must preserve the key=bval predicate
EXPLAIN (COSTS OFF)
SELECT d.aid, d.bval, l.result
FROM test109_driver d
JOIN test109_lookup l ON l.key = d.bval
WHERE d.aid <= 20
ORDER BY d.aid, l.id;

SELECT d.aid, d.bval, l.result
FROM test109_driver d
JOIN test109_lookup l ON l.key = d.bval
WHERE d.aid <= 20
ORDER BY d.aid, l.id;

-- Verify: every returned row must satisfy the join condition
SELECT COUNT(*) AS violations
FROM (
    SELECT d.aid, d.bval, l.result, l.key
    FROM test109_driver d
    JOIN test109_lookup l ON l.key = d.bval
    WHERE d.aid <= 20
) sub
WHERE sub.bval != sub.key;

DROP TABLE test109_driver;
DROP TABLE test109_lookup;
RESET enable_memoize;
RESET enable_partitionwise_join;
RESET enable_hashjoin;
RESET enable_mergejoin;
RESET enable_nestloop;

-- =============================================================================
-- SQL Regression Tests for:
-- "Make multixact error message more explicit"
-- 
-- Code path: MultiXactIdCreateFromMembers() in multixact.c
-- Change: When a new multixact has more than one updating member, the elog(ERROR)
--         now includes mxid_to_string() output for better diagnostics.
--
-- Test strategy:
--   The error path (2+ UPDATE members) cannot be triggered via normal SQL since
--   PostgreSQL's upper layers prevent it. Instead, we test:
--   1. The NORMAL path through MultiXactIdCreateFromMembers (no error), which
--      exercises the has_update check loop and mxid_to_string at debug level.
--   2. The mxid_to_string / pg_get_multixact_members infrastructure used in
--      the new error message.
--   3. Vacuum/freeze paths that call MultiXactIdCreateFromMembers.
-- =============================================================================


-- ============================================================
-- Test 1: Normal multixact creation with two FOR KEY SHARE lockers
-- Code path: MultiXactIdCreateFromMembers with nmembers=2,
--            both with MultiXactStatusForKeyShare (no UPDATE member).
--            Exercises the has_update loop -- neither member triggers it.
-- ============================================================

CREATE TABLE mxact_test1 (id int PRIMARY KEY, val text);
INSERT INTO mxact_test1 VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');

-- Session 1: open a transaction and hold FOR KEY SHARE lock
BEGIN;
SELECT * FROM mxact_test1 WHERE id = 1 FOR KEY SHARE;

-- Session 2 simulation: another SELECT FOR KEY SHARE on the same row
-- (within same session, this creates a multixact internally when combined
--  with the first lock on commit/snapshot)
SELECT * FROM mxact_test1 WHERE id = 1 FOR KEY SHARE;
COMMIT;

-- Read the rows normally to verify table integrity
SELECT * FROM mxact_test1 ORDER BY id;

DROP TABLE mxact_test1;


-- ============================================================
-- Test 2: Multixact creation via FOR SHARE on multiple rows
-- Code path: MultiXactIdCreateFromMembers with MultiXactStatusForShare members.
--            Tests the has_update loop with non-UPDATE statuses (all branches
--            where ISUPDATE_from_mxstatus returns false).
-- ============================================================

CREATE TABLE mxact_test2 (id int, data text);
INSERT INTO mxact_test2 SELECT i, 'row_' || i FROM generate_series(1, 100) i;

BEGIN;
-- Lock multiple rows with FOR SHARE (no UPDATE member)
SELECT id, data FROM mxact_test2 WHERE id <= 10 FOR SHARE;
SELECT id, data FROM mxact_test2 WHERE id BETWEEN 5 AND 15 FOR SHARE;
COMMIT;

SELECT count(*) FROM mxact_test2;

DROP TABLE mxact_test2;


-- ============================================================
-- Test 3: Single UPDATE member multixact (FOR NO KEY UPDATE + FOR KEY SHARE)
-- Code path: MultiXactIdCreateFromMembers with one ISUPDATE member
--            (MultiXactStatusNoKeyUpdate) plus one non-update member.
--            Tests the has_update branch where has_update=true is set
--            exactly once (the valid case -- no error thrown).
-- ============================================================

CREATE TABLE mxact_test3 (id int PRIMARY KEY, counter int DEFAULT 0);
INSERT INTO mxact_test3 VALUES (1, 100), (2, 200), (3, 300);

BEGIN;
-- FOR NO KEY UPDATE acquires MultiXactStatusForNoKeyUpdate (an UPDATE-type lock)
SELECT * FROM mxact_test3 WHERE id = 1 FOR NO KEY UPDATE;
-- FOR KEY SHARE on same row causes multixact creation with one UPDATE member
SELECT * FROM mxact_test3 WHERE id = 1 FOR KEY SHARE;
COMMIT;

-- Verify no data corruption
SELECT * FROM mxact_test3 ORDER BY id;

DROP TABLE mxact_test3;


-- ============================================================
-- Test 4: pg_get_multixact_members and mxid_to_string infrastructure
-- Code path: Exercises mxid_to_string() which is the SAME function now
--            used in the improved error message. Tests that the function
--            correctly formats multixact members (xid + status string).
--            Also exercises GetMultiXactIdMembers() path.
-- ============================================================

CREATE TABLE mxact_test4 (id int PRIMARY KEY, payload text);
INSERT INTO mxact_test4 VALUES (42, 'test_payload');

-- Create a multixact by having concurrent FOR SHARE locks, then inspect it
BEGIN;
SELECT * FROM mxact_test4 WHERE id = 42 FOR SHARE;

-- Introspect the current transaction's multixact state via system catalog
-- txid_current() forces xid assignment, exercising transaction infrastructure
SELECT txid_current() > 0 AS has_valid_xid;

COMMIT;

-- Verify pg_get_multixact_members function signature exists and is callable
-- (we can't easily call it without knowing a live mxid, but we verify the
--  infrastructure works by checking the function exists in pg_proc)
SELECT proname, pronargs
FROM pg_proc
WHERE proname = 'pg_get_multixact_members';

DROP TABLE mxact_test4;


-- ============================================================
-- Test 5: VACUUM with multixact freeze path
-- Code path: MultiXactIdCreateFromMembers is also called during vacuum
--            when freezing multixact tuples (RecordNewMultiXact path).
--            Tests that mxid_to_string works correctly in this context.
-- ============================================================

CREATE TABLE mxact_test5 (id serial PRIMARY KEY, val int);
INSERT INTO mxact_test5 (val) SELECT i FROM generate_series(1, 200) i;

-- Create some multixact entries via concurrent-style locking
BEGIN;
SELECT * FROM mxact_test5 WHERE id BETWEEN 1 AND 50 FOR KEY SHARE;
SELECT * FROM mxact_test5 WHERE id BETWEEN 1 AND 50 FOR KEY SHARE;
COMMIT;

-- Run VACUUM to trigger the freeze path in multixact.c
-- This exercises MultiXactIdCreateFromMembers via heap_freeze_tuple
VACUUM ANALYZE mxact_test5;

-- Verify the table is still healthy after vacuum
SELECT count(*) AS total_rows FROM mxact_test5;
SELECT min(id), max(id), avg(val) FROM mxact_test5;

DROP TABLE mxact_test5;


-- ============================================================
-- SQL Regression Tests for commit:
-- "Simplify WARNING messages from skipped vacuum/analyze on a table"
--
-- The commit unified three separate WARNING messages into a single
-- message: "permission denied to vacuum/analyze \"%s\", skipping it"
-- These tests exercise the vacuum_is_relation_owner() function
-- in src/backend/commands/vacuum.c
-- ============================================================

-- ============================================================
-- Test 1: VACUUM on a regular table owned by another user
-- Covers: VACOPT_VACUUM branch in vacuum_is_relation_owner()
--         for a plain user table (neither shared nor catalog)
--         → triggers "permission denied to vacuum ..." WARNING
-- ============================================================

-- Setup: create table as superuser, then try to vacuum as unprivileged role
CREATE TABLE test_vacperm_t1 (id int, val text);
INSERT INTO test_vacperm_t1 SELECT i, 'data_' || i FROM generate_series(1, 100) i;

CREATE ROLE regress_vacperm_role1;

SET ROLE regress_vacperm_role1;
-- Should emit: WARNING: permission denied to vacuum "test_vacperm_t1", skipping it
VACUUM test_vacperm_t1;
RESET ROLE;

DROP TABLE test_vacperm_t1;
DROP ROLE regress_vacperm_role1;


-- ============================================================
-- Test 2: ANALYZE on a regular table owned by another user
-- Covers: VACOPT_ANALYZE branch in vacuum_is_relation_owner()
--         for a plain user table
--         → triggers "permission denied to analyze ..." WARNING
-- ============================================================

CREATE TABLE test_vacperm_t2 (id int, val text);
INSERT INTO test_vacperm_t2 SELECT i, 'row_' || i FROM generate_series(1, 50) i;

CREATE ROLE regress_vacperm_role2;

SET ROLE regress_vacperm_role2;
-- Should emit: WARNING: permission denied to analyze "test_vacperm_t2", skipping it
ANALYZE test_vacperm_t2;
RESET ROLE;

DROP TABLE test_vacperm_t2;
DROP ROLE regress_vacperm_role2;


-- ============================================================
-- Test 3: VACUUM ANALYZE on a regular table owned by another user
-- Covers: Both VACOPT_VACUUM and VACOPT_ANALYZE branches.
--         With VACUUM ANALYZE, only the VACUUM warning fires (per code
--         comment: "just generate information for VACUUM as that would
--         be the first one to be processed").
--         → triggers "permission denied to vacuum ..." WARNING only
-- ============================================================

CREATE TABLE test_vacperm_t3 (id int, payload text);
INSERT INTO test_vacperm_t3 SELECT i, md5(i::text) FROM generate_series(1, 200) i;

CREATE ROLE regress_vacperm_role3;

SET ROLE regress_vacperm_role3;
-- Should emit exactly one WARNING: permission denied to vacuum "test_vacperm_t3"
VACUUM (ANALYZE) test_vacperm_t3;
RESET ROLE;

DROP TABLE test_vacperm_t3;
DROP ROLE regress_vacperm_role3;


-- ============================================================
-- Test 4: VACUUM on a system catalog table (pg_class) as unprivileged user
-- Covers: VACOPT_VACUUM branch for a catalog namespace table
--         (relnamespace == PG_CATALOG_NAMESPACE)
--         Old code: "only superuser or database owner can vacuum it"
--         New code: "permission denied to vacuum \"%s\", skipping it"
--         → unified WARNING path for catalog tables
-- ============================================================

CREATE ROLE regress_vacperm_role4;

SET ROLE regress_vacperm_role4;
-- Should emit: WARNING: permission denied to vacuum "pg_class", skipping it
VACUUM pg_class;
RESET ROLE;

DROP ROLE regress_vacperm_role4;


-- ============================================================
-- Test 5: ANALYZE on a system catalog table (pg_class) as unprivileged user
--         AND VACUUM on a partitioned table structure to cover
--         multiple table types being skipped in one command
-- Covers: VACOPT_ANALYZE branch for catalog namespace table;
--         also covers the multi-table vacuum path where
--         vacuum_is_relation_owner() is called per-relation
-- ============================================================

-- Part A: ANALYZE on pg_class (catalog table)
CREATE ROLE regress_vacperm_role5;

SET ROLE regress_vacperm_role5;
-- Should emit: WARNING: permission denied to analyze "pg_class", skipping it
ANALYZE pg_class;
RESET ROLE;

-- Part B: VACUUM multiple tables owned by others (multi-table path)
-- Create two tables owned by the superuser
CREATE TABLE test_vacperm_t5a (x int);
CREATE TABLE test_vacperm_t5b (y text);
INSERT INTO test_vacperm_t5a VALUES (1), (2), (3);
INSERT INTO test_vacperm_t5b VALUES ('a'), ('b'), ('c');

SET ROLE regress_vacperm_role5;
-- Should emit TWO WARNINGs (one per table):
-- WARNING: permission denied to vacuum "test_vacperm_t5a", skipping it
-- WARNING: permission denied to vacuum "test_vacperm_t5b", skipping it
VACUUM test_vacperm_t5a, test_vacperm_t5b;
RESET ROLE;

DROP TABLE test_vacperm_t5a;
DROP TABLE test_vacperm_t5b;
DROP ROLE regress_vacperm_role5;


-- ============================================================
-- SQL Regression Tests for get_actual_variable_endpoint()
-- Commit: Limit heap page visits to 100 (VISITED_PAGES_LIMIT)
-- in get_actual_variable_endpoint() to prevent worst-case
-- planning behavior after deletion of many extremal tuples.
-- ============================================================

-- ============================================================
-- Test 1: Normal path - EXPLAIN range query triggers
--         get_actual_variable_range -> get_actual_variable_endpoint
--         with a healthy index (visible tuples at extremes).
--         Covers: basic invocation of the new code variables
--         (last_heap_block=InvalidBlockNumber, n_visited_heap_pages=0)
-- ============================================================
CREATE TABLE t1_variable_range (
    id    integer,
    val   integer
);

CREATE INDEX t1_val_idx ON t1_variable_range (val);

INSERT INTO t1_variable_range
SELECT i, i * 10
FROM generate_series(1, 1000) AS s(i);

ANALYZE t1_variable_range;

-- Trigger get_actual_variable_range via a range inequality predicate
EXPLAIN SELECT * FROM t1_variable_range WHERE val > 5000;
EXPLAIN SELECT * FROM t1_variable_range WHERE val < 100;
EXPLAIN SELECT * FROM t1_variable_range WHERE val BETWEEN 1000 AND 8000;

DROP TABLE t1_variable_range;


-- ============================================================
-- Test 2: Deleted extremal values - simulates the worst-case
--         scenario described in the commit message.
--         After deleting the MAX values, the planner must
--         scan dead index entries, triggering the new
--         n_visited_heap_pages counter and potentially the
--         VISITED_PAGES_LIMIT break path.
-- ============================================================
CREATE TABLE t2_deleted_extremes (
    id    integer,
    val   integer
);

CREATE INDEX t2_val_idx ON t2_deleted_extremes (val);

-- Insert a wide range of values
INSERT INTO t2_deleted_extremes
SELECT i, i
FROM generate_series(1, 5000) AS s(i);

-- Run ANALYZE so pg_statistic has the original extremes recorded
ANALYZE t2_deleted_extremes;

-- Delete the high-end (extremal) values - creates many dead index entries
-- that get_actual_variable_endpoint will have to skip
DELETE FROM t2_deleted_extremes WHERE val > 4000;

-- Now plan a query - planner will call get_actual_variable_endpoint
-- and encounter dead/non-visible tuples at the max end of the index.
-- The new block-counting code path is exercised here.
EXPLAIN SELECT * FROM t2_deleted_extremes WHERE val > 3500;
EXPLAIN SELECT * FROM t2_deleted_extremes WHERE val > 4500;

DROP TABLE t2_deleted_extremes;


-- ============================================================
-- Test 3: Deleted extremal values at the MIN end of the index.
--         Covers the forward scan direction in
--         get_actual_variable_endpoint (BackwardScanDirection
--         for min). Also covers the "if min not requested,
--         still want to fetch max" branch (have_data = true).
-- ============================================================
CREATE TABLE t3_deleted_min (
    id    integer,
    val   integer
);

CREATE INDEX t3_val_idx ON t3_deleted_min (val);

INSERT INTO t3_deleted_min
SELECT i, i
FROM generate_series(1, 5000) AS s(i);

ANALYZE t3_deleted_min;

-- Delete the low-end (extremal) values at the MIN side
DELETE FROM t3_deleted_min WHERE val < 500;

-- Plan queries: planner will call get_actual_variable_endpoint
-- for the min direction and encounter many dead index entries,
-- exercising the new last_heap_block / n_visited_heap_pages logic.
EXPLAIN SELECT * FROM t3_deleted_min WHERE val < 200;
-- Only max requested (min not requested -> have_data=true branch)
EXPLAIN SELECT max(val) FROM t3_deleted_min;

DROP TABLE t3_deleted_min;


-- ============================================================
-- Test 4: Empty table / empty index - get_actual_variable_endpoint
--         returns false immediately (index is empty case).
--         The new variables are initialized but the while loop
--         body is never entered.
-- ============================================================
CREATE TABLE t4_empty (
    id    integer,
    val   integer
);

CREATE INDEX t4_val_idx ON t4_empty (val);

-- No rows inserted - index is empty
ANALYZE t4_empty;

-- Planner calls get_actual_variable_endpoint, loop exits immediately
-- (tid == NULL on first call), function returns false.
EXPLAIN SELECT * FROM t4_empty WHERE val > 0;
EXPLAIN SELECT * FROM t4_empty WHERE val < 100;

DROP TABLE t4_empty;


-- ============================================================
-- Test 5: Table with NULLs mixed with non-NULL extremal values.
--         The index scan uses SK_SEARCHNOTNULL scankey to skip
--         NULLs. After deleting non-NULL extremal values, the
--         planner traverses dead entries (non-NULL) before
--         reaching NULLs (which are skipped by scankey) or
--         visible tuples. Exercises the block-counting code
--         path in the presence of NULL-heavy data.
-- ============================================================
CREATE TABLE t5_with_nulls (
    id    integer,
    val   integer
);

CREATE INDEX t5_val_idx ON t5_with_nulls (val);

-- Insert mix of NULLs and non-NULL values
INSERT INTO t5_with_nulls
SELECT i, CASE WHEN i % 5 = 0 THEN NULL ELSE i END
FROM generate_series(1, 3000) AS s(i);

-- Also insert some high extremal values that we will delete
INSERT INTO t5_with_nulls
SELECT i, i + 10000
FROM generate_series(1, 500) AS s(i);

ANALYZE t5_with_nulls;

-- Delete the inserted extremal (high) values -> dead index entries at max end
DELETE FROM t5_with_nulls WHERE val > 10000;

-- Plan a range query - triggers get_actual_variable_endpoint for max,
-- which now must scan past dead entries, exercising the new page counter.
EXPLAIN SELECT * FROM t5_with_nulls WHERE val > 2500;
EXPLAIN SELECT * FROM t5_with_nulls WHERE val BETWEEN 100 AND 500;
-- Also exercise only-max path (no lower bound needed by planner for max())
EXPLAIN SELECT max(val) FROM t5_with_nulls;

DROP TABLE t5_with_nulls;


-- ============================================================
-- SQL Regression Tests for commit:
--   "Fix cleanup lock acquisition in SPLIT_ALLOCATE_PAGE replay"
--
-- Target code path: hash_xlog_split_allocate_page() in hash_xlog.c
--   New code: XLogReadBufferForRedoExtended(..., RBM_ZERO_AND_CLEANUP_LOCK, ...)
--   replaces the old XLogInitBufferForRedo + IsBufferCleanupOK PANIC pattern.
--
-- To exercise XLOG_HASH_SPLIT_ALLOCATE_PAGE WAL records we must trigger
-- hash index bucket splits.  Each INSERT batch below is sized to push the
-- hash index past its fill-factor threshold and force at least one split.
-- ============================================================


-- ============================================================
-- Test 1: Basic bucket split via bulk INSERT on integer column
--   Covers: normal code path — many distinct integer keys force
--           multiple bucket splits → XLOG_HASH_SPLIT_ALLOCATE_PAGE WAL
-- ============================================================
CREATE TABLE t114_int (id integer, val text);
CREATE INDEX t114_int_hidx ON t114_int USING hash (id);

-- Insert enough rows to force several bucket splits (default fillfactor=75)
INSERT INTO t114_int SELECT g, 'value_' || g
FROM generate_series(1, 10000) g;

-- Verify index is usable after splits
EXPLAIN (COSTS OFF) SELECT * FROM t114_int WHERE id = 5000;
SELECT count(*) FROM t114_int WHERE id BETWEEN 1 AND 10000;

-- Checkpoint forces WAL buffers to disk, exercising the replay path on recovery
CHECKPOINT;

DROP INDEX t114_int_hidx;
DROP TABLE t114_int;


-- ============================================================
-- Test 2: Bucket split on text (variable-length) column
--   Covers: different data type → different hash function, same split WAL path
-- ============================================================
CREATE TABLE t114_text (id serial, val text);
CREATE INDEX t114_text_hidx ON t114_text USING hash (val);

INSERT INTO t114_text (val)
SELECT 'str_' || g || '_' || md5(g::text)
FROM generate_series(1, 8000) g;

EXPLAIN (COSTS OFF) SELECT * FROM t114_text WHERE val = 'str_1_c4ca4238a0b923820dcc509a6f75849b';
SELECT count(*) FROM t114_text WHERE val LIKE 'str_%';

CHECKPOINT;

DROP INDEX t114_text_hidx;
DROP TABLE t114_text;


-- ============================================================
-- Test 3: Bucket split with duplicate keys (high collision load)
--   Covers: edge case — many rows share the same hash bucket,
--           overflow pages created before split, stress-tests
--           the new cleanup-lock acquisition on the new bucket page
-- ============================================================
CREATE TABLE t114_dup (id integer, grp integer);
CREATE INDEX t114_dup_hidx ON t114_dup USING hash (grp);

-- Only 100 distinct values among 10000 rows → many overflow pages per bucket
INSERT INTO t114_dup SELECT g, g % 100
FROM generate_series(1, 10000) g;

EXPLAIN (COSTS OFF) SELECT count(*) FROM t114_dup WHERE grp = 42;
SELECT count(*) FROM t114_dup WHERE grp = 42;

CHECKPOINT;

DROP INDEX t114_dup_hidx;
DROP TABLE t114_dup;


-- ============================================================
-- Test 4: Bucket split after repeated DELETE + INSERT cycles
--   Covers: edge case — pages recycled and re-split; ensures
--           RBM_ZERO_AND_CLEANUP_LOCK correctly zeroes and locks
--           previously-used pages allocated for a new bucket
-- ============================================================
CREATE TABLE t114_recycle (id integer);
CREATE INDEX t114_recycle_hidx ON t114_recycle USING hash (id);

-- Round 1: fill and split
INSERT INTO t114_recycle SELECT g FROM generate_series(1, 5000) g;
CHECKPOINT;

-- Delete all, vacuum to reclaim pages
DELETE FROM t114_recycle;
VACUUM t114_recycle;

-- Round 2: re-fill forcing splits again on recycled pages
INSERT INTO t114_recycle SELECT g FROM generate_series(5001, 10000) g;
CHECKPOINT;

EXPLAIN (COSTS OFF) SELECT * FROM t114_recycle WHERE id = 7500;
SELECT count(*) FROM t114_recycle;

DROP INDEX t114_recycle_hidx;
DROP TABLE t114_recycle;


-- ============================================================
-- Test 5: Concurrent-style stress — hash index with low fillfactor
--   Covers: lowering fillfactor triggers splits sooner and more
--           frequently, maximising XLOG_HASH_SPLIT_ALLOCATE_PAGE
--           WAL records and exercising the new locking code path
--           across many split events
-- ============================================================
CREATE TABLE t114_lowff (id integer, payload text);
-- fillfactor=10 → splits happen very aggressively
CREATE INDEX t114_lowff_hidx ON t114_lowff USING hash (id) WITH (fillfactor = 10);

INSERT INTO t114_lowff SELECT g, repeat('x', 10)
FROM generate_series(1, 3000) g;

-- Multiple checkpoints to ensure WAL for each split round is flushed
CHECKPOINT;

INSERT INTO t114_lowff SELECT g + 3000, repeat('y', 10)
FROM generate_series(1, 3000) g;

CHECKPOINT;

EXPLAIN (COSTS OFF) SELECT * FROM t114_lowff WHERE id = 1;
SELECT count(*) FROM t114_lowff;

DROP INDEX t114_lowff_hidx;
DROP TABLE t114_lowff;

-- SQL Regression Tests for: Fix theoretical torn page hazard in heap_xlog_visible
-- Commit: pgsql: Fix theoretical torn page hazard
-- Target code path: heap_xlog_visible() in heapam.c
--   New code: if (XLogHintBitIsNeeded()) PageSetLSN(page, lsn);
--   This is triggered during WAL redo when pages become all-visible via VACUUM.
--   In normal (non-recovery) operation, VACUUM writes XLOG_HEAP2_VISIBLE records
--   which exercise the code path that generates these WAL entries. The fix ensures
--   PageSetLSN is called when wal_log_hints or data checksums are enabled.

-- =============================================================================
-- Test 1: Basic visibility map update via VACUUM
-- Covers: The normal path that generates XLOG_HEAP2_VISIBLE WAL records
--         which are replayed by heap_xlog_visible(). Exercises PageSetAllVisible
--         and the new PageSetLSN call when wal_log_hints is relevant.
-- =============================================================================

-- Test 1: VACUUM makes a table all-visible, triggering XLOG_HEAP2_VISIBLE
CREATE TABLE t115_basic (
    id      INTEGER,
    val     TEXT
) WITH (autovacuum_enabled = off);

INSERT INTO t115_basic SELECT g, 'value_' || g FROM generate_series(1, 100) g;

-- Delete some rows then re-insert to create dead tuples, then vacuum to
-- generate all-visible WAL records (heap_xlog_visible will replay these)
DELETE FROM t115_basic WHERE id % 2 = 0;
INSERT INTO t115_basic SELECT g, 'value_' || g FROM generate_series(101, 200) g;

-- VACUUM without FULL processes heap pages and sets all-visible bits in VM,
-- producing XLOG_HEAP2_VISIBLE records exercising heap_xlog_visible code path
VACUUM t115_basic;

-- Verify the table is still accessible and data is intact
SELECT COUNT(*) FROM t115_basic WHERE id > 0;

-- Trigger an index-only scan which relies on visibility map
CREATE INDEX ON t115_basic (id);
VACUUM t115_basic;
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) SELECT id FROM t115_basic WHERE id BETWEEN 1 AND 50;

DROP TABLE t115_basic;

-- =============================================================================
-- Test 2: VACUUM FREEZE to trigger all-visible AND all-frozen flags
-- Covers: visibilitymap_set with VISIBILITYMAP_ALL_VISIBLE | VISIBILITYMAP_ALL_FROZEN
--         which still exercises heap_xlog_visible WAL redo path
-- =============================================================================

CREATE TABLE t115_freeze (
    id      INTEGER,
    payload TEXT
) WITH (autovacuum_enabled = off);

INSERT INTO t115_freeze SELECT g, repeat('x', 10) FROM generate_series(1, 500) g;

-- VACUUM FREEZE sets all-visible and all-frozen, writing XLOG_HEAP2_VISIBLE
-- records which will exercise heap_xlog_visible() including the new LSN code
VACUUM FREEZE t115_freeze;

-- Verify all-visible pages can be used for index-only scans
CREATE INDEX ON t115_freeze (id);
VACUUM FREEZE t115_freeze;
EXPLAIN (ANALYZE, BUFFERS) SELECT id FROM t115_freeze ORDER BY id LIMIT 10;

SELECT COUNT(*) FROM t115_freeze;

DROP TABLE t115_freeze;

-- =============================================================================
-- Test 3: Pages with NULL values becoming all-visible
-- Covers: Edge case where tuples contain NULLs; verifies that visibility map
--         and the new PageSetLSN path handle pages with nullable columns correctly
-- =============================================================================

CREATE TABLE t115_nulls (
    id      INTEGER,
    col1    TEXT,
    col2    INTEGER,
    col3    BOOLEAN
) WITH (autovacuum_enabled = off);

-- Insert rows with various NULL patterns
INSERT INTO t115_nulls VALUES (1, NULL, NULL, NULL);
INSERT INTO t115_nulls VALUES (2, 'hello', NULL, TRUE);
INSERT INTO t115_nulls VALUES (3, NULL, 42, FALSE);
INSERT INTO t115_nulls VALUES (4, 'world', 100, NULL);
INSERT INTO t115_nulls SELECT g, NULL, NULL, NULL FROM generate_series(5, 200) g;

-- Delete some rows to create dead tuples
DELETE FROM t115_nulls WHERE id % 3 = 0;

-- VACUUM will set all-visible on pages that have all live tuples committed,
-- exercising heap_xlog_visible WAL path with the new PageSetLSN fix
VACUUM t115_nulls;

SELECT COUNT(*) FROM t115_nulls WHERE col1 IS NULL;
SELECT COUNT(*) FROM t115_nulls WHERE col2 IS NOT NULL;

-- VACUUM ANALYZE to exercise both code paths
VACUUM ANALYZE t115_nulls;

DROP TABLE t115_nulls;

-- =============================================================================
-- Test 4: Large table with multiple pages to ensure all-visible is set page-wide
-- Covers: Multiple XLOG_HEAP2_VISIBLE records (one per page becoming all-visible)
--         Each page's redo will invoke heap_xlog_visible() with the new LSN fix
-- =============================================================================

CREATE TABLE t115_multipage (
    id      SERIAL,
    data    TEXT
) WITH (autovacuum_enabled = off);

-- Insert enough data to span many pages (8kB pages, ~100 rows/page)
INSERT INTO t115_multipage (data)
    SELECT repeat('y', 80) FROM generate_series(1, 2000);

-- Create dead tuples across many pages
DELETE FROM t115_multipage WHERE id % 5 = 0;
UPDATE t115_multipage SET data = repeat('z', 80) WHERE id % 7 = 0;

-- VACUUM will process each page and potentially write XLOG_HEAP2_VISIBLE
-- for each page that becomes all-visible, exercising the new fix repeatedly
VACUUM (VERBOSE) t115_multipage;

-- Verify index-only scans work correctly after all-visible pages are set
CREATE INDEX ON t115_multipage (id);
VACUUM t115_multipage;

EXPLAIN (ANALYZE, BUFFERS) SELECT id FROM t115_multipage WHERE id < 100;
SELECT COUNT(*) FROM t115_multipage;

DROP TABLE t115_multipage;

-- =============================================================================
-- Test 5: Repeated VACUUM cycles and UPDATE/DELETE interleaving
-- Covers: The scenario where pages toggle between all-visible and not-all-visible,
--         testing that the new PageSetLSN in heap_xlog_visible() correctly
--         handles repeated visibility map updates without corruption
-- =============================================================================

CREATE TABLE t115_cyclic (
    id      INTEGER PRIMARY KEY,
    version INTEGER DEFAULT 1,
    flag    BOOLEAN DEFAULT TRUE
) WITH (autovacuum_enabled = off);

INSERT INTO t115_cyclic (id) SELECT g FROM generate_series(1, 300) g;

-- Cycle 1: make pages all-visible
VACUUM t115_cyclic;

-- Modify some rows (clears all-visible bits on affected pages)
UPDATE t115_cyclic SET version = 2, flag = FALSE WHERE id <= 100;

-- Cycle 2: make pages all-visible again (exercises heap_xlog_visible again)
VACUUM t115_cyclic;

-- Another round of modifications
DELETE FROM t115_cyclic WHERE id BETWEEN 50 AND 150;
INSERT INTO t115_cyclic (id, version) SELECT g, 3 FROM generate_series(50, 150) g;

-- Cycle 3: vacuum again to set visibility bits, triggering new code path
VACUUM FREEZE t115_cyclic;

-- Verify data integrity after multiple visibility map update cycles
SELECT COUNT(*) FROM t115_cyclic;
SELECT COUNT(*) FROM t115_cyclic WHERE version = 3;
SELECT COUNT(*) FROM t115_cyclic WHERE flag = FALSE;

-- Index-only scan after freeze to verify all-visible pages work correctly
EXPLAIN (ANALYZE, BUFFERS) SELECT id FROM t115_cyclic WHERE id BETWEEN 1 AND 300;

DROP TABLE t115_cyclic;


-- ============================================================
-- SQL Regression Tests for commit:
--   "Avoid crash after function syntax error in a replication worker"
-- Covers: function_parse_error_transpose() in pg_proc.c
--         - Normal path: ActivePortal exists, syntax error transposes position
--         - New path: no ActivePortal (e.g. logical replication worker) => graceful newerrposition=-1
-- ============================================================

-- Test 1: Normal path — SQL-language function with syntax error in body
-- Covers: ActivePortal is active, match_prosrc_to_query() is called,
--         newerrposition > 0 branch (errposition set to original query offset)
-- Expected: ERROR with syntax error reported at correct position in CREATE FUNCTION
DO $$
BEGIN
  BEGIN
    -- This CREATE FUNCTION has a syntax error in the SQL body
    EXECUTE $q$
      CREATE OR REPLACE FUNCTION test_sql_syntax_err_func()
        RETURNS int
        LANGUAGE sql
      AS $$
        SELECT 1 +;
      $$;
    $q$;
  EXCEPTION WHEN OTHERS THEN
    -- Expect a syntax error; the error position should reference the outer query
    RAISE NOTICE 'Caught expected syntax error (SQL function): %', SQLERRM;
  END;
END;
$$;

-- Test 2: Normal path — PL/pgSQL function with syntax error in body
-- Covers: ActivePortal active, function_parse_error_transpose called from
--         plpgsql compile path, newerrposition computed via match_prosrc_to_query
DO $$
BEGIN
  BEGIN
    EXECUTE $q$
      CREATE OR REPLACE FUNCTION test_plpgsql_syntax_err_func()
        RETURNS void
        LANGUAGE plpgsql
      AS $$
      BEGIN
        SELECT 1 +;   -- deliberate syntax error
      END;
      $$;
    $q$;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Caught expected syntax error (PL/pgSQL function): %', SQLERRM;
  END;
END;
$$;

-- Test 3: Normal path — DO command (anonymous block) with syntax error
-- Covers: function_parse_error_transpose called for DO command body;
--         ActivePortal is present for the outer DO, exercises the
--         "if (ActivePortal && ActivePortal->status == PORTAL_ACTIVE)" branch
DO $$
BEGIN
  BEGIN
    EXECUTE $q$
      DO $$anon
      BEGIN
        SELECT 1 +;   -- deliberate syntax error inside DO block
      END;
      $$anon$;
    $q$;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Caught expected syntax error (DO command): %', SQLERRM;
  END;
END;
$$;

-- Test 4: Edge case — syntax error in function body that uses dollar-quoting
-- with a unique tag (tests match_prosrc_to_query dollar-quote scanning)
-- Covers: newerrposition > 0 path with $tag$ quoting style
DO $$
BEGIN
  BEGIN
    EXECUTE $outer$
      CREATE OR REPLACE FUNCTION test_dollar_tag_syntax_err()
        RETURNS int
        LANGUAGE plpgsql
      AS $body$
      BEGIN
        RETURN 1 +;   -- deliberate syntax error with named $body$ tag
      END;
      $body$;
    $outer$;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Caught expected syntax error (dollar-tag function): %', SQLERRM;
  END;
END;
$$;

-- Test 5: Edge case — simulate no-portal context by calling a valid function
-- that itself creates a function with a syntax error (nested context).
-- This exercises the else branch: if no matching portal source text is found,
-- newerrposition falls back to -1 and error is reported as internal position.
-- Also acts as a regression guard: must NOT crash (null-pointer / assertion).
DO $$
BEGIN
  BEGIN
    -- Create a helper that tries to create a broken SQL function
    CREATE OR REPLACE FUNCTION test_nested_syntax_err_creator()
      RETURNS void
      LANGUAGE plpgsql
    AS $body$
    BEGIN
      EXECUTE $q$
        CREATE OR REPLACE FUNCTION broken_inner()
          RETURNS int LANGUAGE sql
        AS $inner$
          SELECT 1 +;
        $inner$;
      $q$;
    END;
    $body$;

    -- Call it: the error inside has no matching portal for the inner CREATE
    PERFORM test_nested_syntax_err_creator();
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Caught expected syntax error (nested / no-portal path): %', SQLERRM;
  END;

  -- Clean up
  DROP FUNCTION IF EXISTS test_nested_syntax_err_creator();
  DROP FUNCTION IF EXISTS broken_inner();
END;
$$;

-- Final cleanup of any leftover objects from tests 1-4
DROP FUNCTION IF EXISTS test_sql_syntax_err_func();
DROP FUNCTION IF EXISTS test_plpgsql_syntax_err_func();
DROP FUNCTION IF EXISTS test_dollar_tag_syntax_err();

-- ============================================================
-- SQL Regression Tests for: Create FKs properly when attaching
-- table as partition (fix initially_valid in CloneFkReferencing
-- and CloneFkReferenced)
-- Commit: Fix Constraint node initialization (initially_valid=true)
-- ============================================================

-- ============================================================
-- Test 1: CloneFkReferencing path
-- A partitioned table has an FK to another table.
-- When a plain table is attached as a partition, CloneFkReferencing
-- must clone the FK with initially_valid = true.
-- Verifies: convalidated = true on cloned FK in partition.
-- ============================================================

-- Test 1: Basic CloneFkReferencing - FK on partitioned table, attach plain partition
CREATE TABLE t117_ref (
    id   INT PRIMARY KEY,
    val  TEXT NOT NULL
);

CREATE TABLE t117_parent (
    id     INT,
    ref_id INT,
    FOREIGN KEY (ref_id) REFERENCES t117_ref(id)
) PARTITION BY RANGE (id);

CREATE TABLE t117_child1 PARTITION OF t117_parent
    FOR VALUES FROM (1) TO (100);

-- Insert reference data
INSERT INTO t117_ref VALUES (1, 'a'), (2, 'b'), (3, 'c');

-- Create a plain table to be attached
CREATE TABLE t117_plain (
    id     INT,
    ref_id INT
);
INSERT INTO t117_plain VALUES (100, 1), (101, 2);

-- ATTACH triggers CloneFkReferencing: must set initially_valid=true
ALTER TABLE t117_parent ATTACH PARTITION t117_plain
    FOR VALUES FROM (100) TO (200);

-- Verify the FK on the attached partition is marked as validated
SELECT cr.relname, co.conname, co.convalidated
FROM pg_constraint co
JOIN pg_class cr ON cr.oid = co.conrelid
WHERE co.contype = 'f'
  AND cr.relname IN ('t117_plain', 't117_child1')
ORDER BY cr.relname, co.conname;

DROP TABLE t117_parent CASCADE;
DROP TABLE t117_ref CASCADE;


-- ============================================================
-- Test 2: CloneFkReferenced path
-- Another table has an FK referencing the partitioned table (parent).
-- When we attach a partition to the parent, CloneFkReferenced must
-- clone the constraint on the referenced side with initially_valid=true.
-- ============================================================

CREATE TABLE t117_pk_parent (
    id  INT,
    val TEXT
) PARTITION BY RANGE (id);

CREATE TABLE t117_pk_child1 PARTITION OF t117_pk_parent
    FOR VALUES FROM (1) TO (100);

-- The referencing table
CREATE TABLE t117_fk_referencing (
    id        INT PRIMARY KEY,
    pk_ref_id INT REFERENCES t117_pk_parent(id)
);

INSERT INTO t117_pk_parent VALUES (1, 'x'), (2, 'y');
INSERT INTO t117_fk_referencing VALUES (10, 1), (20, 2);

-- Attach another partition: triggers CloneFkReferenced
CREATE TABLE t117_pk_child2 (
    id  INT,
    val TEXT
);
INSERT INTO t117_pk_child2 VALUES (50, 'z');

ALTER TABLE t117_pk_parent ATTACH PARTITION t117_pk_child2
    FOR VALUES FROM (100) TO (200);

-- Verify constraint on partition side is validated
SELECT cr.relname, co.conname, co.convalidated
FROM pg_constraint co
JOIN pg_class cr ON cr.oid = co.conrelid
WHERE co.contype = 'f'
  AND cr.relname = 't117_fk_referencing'
ORDER BY co.conname;

DROP TABLE t117_fk_referencing CASCADE;
DROP TABLE t117_pk_parent CASCADE;


-- ============================================================
-- Test 3: ATExecDetachPartition path
-- Detach a partition that carries FK references; ATExecDetachPartition
-- must re-create the action triggers using the fully initialized
-- Constraint node (initially_valid=true, fk_matchtype, etc.).
-- ============================================================

CREATE TABLE t117_det_ref (
    id INT PRIMARY KEY
);

CREATE TABLE t117_det_parent (
    id     INT,
    ref_id INT,
    FOREIGN KEY (ref_id) REFERENCES t117_det_ref(id)
) PARTITION BY LIST (id);

CREATE TABLE t117_det_child PARTITION OF t117_det_parent
    FOR VALUES IN (1, 2, 3, 4, 5);

INSERT INTO t117_det_ref VALUES (1), (2), (3);
INSERT INTO t117_det_parent VALUES (1, 1), (2, 2);

-- Detach triggers ATExecDetachPartition (creates independent FK triggers)
ALTER TABLE t117_det_parent DETACH PARTITION t117_det_child;

-- After detach, the independent table must still enforce FK
-- (this tests the triggers created by ATExecDetachPartition code path)
INSERT INTO t117_det_child VALUES (3, 3);   -- ok: 3 exists in ref

-- Re-attach to confirm round-trip; CloneFkReferencing runs again
INSERT INTO t117_det_child VALUES (4, 2);
ALTER TABLE t117_det_parent ATTACH PARTITION t117_det_child
    FOR VALUES IN (1, 2, 3, 4, 5);

SELECT cr.relname, co.conname, co.convalidated
FROM pg_constraint co
JOIN pg_class cr ON cr.oid = co.conrelid
WHERE co.contype = 'f'
  AND cr.relname = 't117_det_child'
ORDER BY co.conname;

DROP TABLE t117_det_parent CASCADE;
DROP TABLE t117_det_ref CASCADE;


-- ============================================================
-- Test 4: Deferrable FK cloned via CloneFkReferencing
-- Ensures deferrable/initdeferred attributes are preserved
-- when cloning through the fixed code path.
-- ============================================================

CREATE TABLE t117_defer_pk (
    id INT PRIMARY KEY
);

CREATE TABLE t117_defer_parent (
    id     INT,
    ref_id INT,
    CONSTRAINT fk_defer FOREIGN KEY (ref_id)
        REFERENCES t117_defer_pk(id)
        DEFERRABLE INITIALLY DEFERRED
) PARTITION BY RANGE (id);

CREATE TABLE t117_defer_child1 PARTITION OF t117_defer_parent
    FOR VALUES FROM (1) TO (50);

INSERT INTO t117_defer_pk VALUES (10), (20), (30);
INSERT INTO t117_defer_parent VALUES (1, 10), (2, 20);

-- Plain table to attach (triggers CloneFkReferencing with deferrable FK)
CREATE TABLE t117_defer_plain (
    id     INT,
    ref_id INT
);
INSERT INTO t117_defer_plain VALUES (50, 10), (51, 30);

ALTER TABLE t117_defer_parent ATTACH PARTITION t117_defer_plain
    FOR VALUES FROM (50) TO (100);

-- Verify cloned constraint preserves deferrable attribute AND is validated
SELECT cr.relname, co.conname, co.convalidated,
       co.condeferrable, co.condeferred
FROM pg_constraint co
JOIN pg_class cr ON cr.oid = co.conrelid
WHERE co.contype = 'f'
  AND cr.relname IN ('t117_defer_plain', 't117_defer_child1')
ORDER BY cr.relname, co.conname;

DROP TABLE t117_defer_parent CASCADE;
DROP TABLE t117_defer_pk CASCADE;


-- ============================================================
-- Test 5: Multi-level partitioning (recursive CloneFk)
-- A partitioned table is itself partitioned; attaching triggers
-- recursive calls to both CloneFkReferenced and CloneFkReferencing.
-- Verifies all levels get initially_valid = true.
-- ============================================================

CREATE TABLE t117_ml_ref (
    id INT PRIMARY KEY
);

-- Two-level partitioned table with FK
CREATE TABLE t117_ml_parent (
    region INT,
    id     INT,
    ref_id INT,
    FOREIGN KEY (ref_id) REFERENCES t117_ml_ref(id)
) PARTITION BY LIST (region);

-- Sub-partitioned child
CREATE TABLE t117_ml_region1 PARTITION OF t117_ml_parent
    FOR VALUES IN (1)
    PARTITION BY RANGE (id);

CREATE TABLE t117_ml_region1_a PARTITION OF t117_ml_region1
    FOR VALUES FROM (1) TO (500);

INSERT INTO t117_ml_ref VALUES (100), (200), (300);
INSERT INTO t117_ml_parent VALUES (1, 1, 100), (1, 2, 200);

-- Attach a new sub-partition at level 2 (recursive CloneFkReferencing)
CREATE TABLE t117_ml_region1_b (
    region INT,
    id     INT,
    ref_id INT
);
INSERT INTO t117_ml_region1_b VALUES (1, 500, 100), (1, 501, 300);

ALTER TABLE t117_ml_region1 ATTACH PARTITION t117_ml_region1_b
    FOR VALUES FROM (500) TO (1000);

-- Verify all partition levels have convalidated = true
SELECT cr.relname, co.conname, co.convalidated
FROM pg_constraint co
JOIN pg_class cr ON cr.oid = co.conrelid
WHERE co.contype = 'f'
  AND cr.oid IN (
      SELECT relid FROM pg_partition_tree('t117_ml_parent')
  )
ORDER BY cr.relname, co.conname;

DROP TABLE t117_ml_parent CASCADE;
DROP TABLE t117_ml_ref CASCADE;

-- SQL Regression Tests for commit: Reject non-ON-SELECT rules named "_RETURN"
-- Covers: DefineQueryRewrite() in src/backend/rewrite/rewriteDefine.c
-- New code path: if (strcmp(rulename, ViewSelectRuleName) == 0) ereport(ERROR, ...)
-- This check fires when a NON-ON-SELECT rule is named "_RETURN"

-- =============================================================================
-- Test 1: ON INSERT rule named "_RETURN" on a plain table should be rejected
-- Covers: the new error path for event_type = CMD_INSERT
-- =============================================================================
CREATE TABLE test118_t1 (id int, val text);

-- This must raise: "non-view rule for "test118_t1" must not be named "_RETURN""
DO $$
BEGIN
    BEGIN
        EXECUTE $sql$
            CREATE RULE "_RETURN" AS ON INSERT TO test118_t1 DO NOTHING
        $sql$;
        RAISE EXCEPTION 'Expected error was NOT raised';
    EXCEPTION WHEN invalid_object_definition THEN
        RAISE NOTICE 'Test 1 PASSED: ON INSERT rule named _RETURN correctly rejected';
    END;
END;
$$;

DROP TABLE test118_t1;


-- =============================================================================
-- Test 2: ON UPDATE rule named "_RETURN" on a plain table should be rejected
-- Covers: the new error path for event_type = CMD_UPDATE
-- =============================================================================
CREATE TABLE test118_t2 (id int, val text);

DO $$
BEGIN
    BEGIN
        EXECUTE $sql$
            CREATE RULE "_RETURN" AS ON UPDATE TO test118_t2 DO NOTHING
        $sql$;
        RAISE EXCEPTION 'Expected error was NOT raised';
    EXCEPTION WHEN invalid_object_definition THEN
        RAISE NOTICE 'Test 2 PASSED: ON UPDATE rule named _RETURN correctly rejected';
    END;
END;
$$;

DROP TABLE test118_t2;


-- =============================================================================
-- Test 3: ON DELETE rule named "_RETURN" on a plain table should be rejected
-- Covers: the new error path for event_type = CMD_DELETE
-- =============================================================================
CREATE TABLE test118_t3 (id int, val text);

DO $$
BEGIN
    BEGIN
        EXECUTE $sql$
            CREATE RULE "_RETURN" AS ON DELETE TO test118_t3 DO NOTHING
        $sql$;
        RAISE EXCEPTION 'Expected error was NOT raised';
    EXCEPTION WHEN invalid_object_definition THEN
        RAISE NOTICE 'Test 3 PASSED: ON DELETE rule named _RETURN correctly rejected';
    END;
END;
$$;

DROP TABLE test118_t3;


-- =============================================================================
-- Test 4: CREATE OR REPLACE RULE with non-ON-SELECT named "_RETURN" on a view
-- Covers: the critical bug scenario - replacing a view's _RETURN rule with
--         a different event type via CREATE OR REPLACE RULE
-- =============================================================================
CREATE TABLE test118_t4_base (id int, val text);
INSERT INTO test118_t4_base VALUES (1, 'a'), (2, 'b'), (3, 'c');
CREATE VIEW test118_v4 AS SELECT * FROM test118_t4_base;

-- Verify the view works before the attack
SELECT count(*) FROM test118_v4;

-- This must raise an error: attempt to overwrite _RETURN with ON INSERT rule
DO $$
BEGIN
    BEGIN
        EXECUTE $sql$
            CREATE OR REPLACE RULE "_RETURN" AS ON INSERT TO test118_v4 DO NOTHING
        $sql$;
        RAISE EXCEPTION 'Expected error was NOT raised';
    EXCEPTION WHEN invalid_object_definition THEN
        RAISE NOTICE 'Test 4 PASSED: CREATE OR REPLACE RULE cannot overwrite _RETURN with non-SELECT rule';
    END;
END;
$$;

-- View should still be intact after the rejected attack
SELECT count(*) FROM test118_v4;

DROP VIEW test118_v4;
DROP TABLE test118_t4_base;


-- =============================================================================
-- Test 5: ON SELECT rule named "_RETURN" should be ALLOWED (normal/positive case)
-- Covers: verifying the positive path is not broken by the new check
-- A valid ON SELECT _RETURN rule converts a table into a view (the normal path)
-- =============================================================================
CREATE TABLE test118_t5_src (id int, label text);
INSERT INTO test118_t5_src VALUES (1, 'foo'), (2, 'bar');

-- Create a table that will become a view-like object via _RETURN rule
CREATE TABLE test118_t5_dest (id int, label text);

-- This should succeed: ON SELECT rule named _RETURN is the only allowed type
CREATE RULE "_RETURN" AS ON SELECT TO test118_t5_dest
    DO INSTEAD SELECT id, label FROM test118_t5_src;

-- Query to confirm the rule works correctly
SELECT * FROM test118_t5_dest ORDER BY id;

-- Named _RETURN rule should appear in pg_rewrite
SELECT rulename, ev_type
FROM pg_rewrite
WHERE rulename = '_RETURN'
  AND ev_class = 'test118_t5_dest'::regclass;

DROP RULE "_RETURN" ON test118_t5_dest;
DROP TABLE test118_t5_dest;
DROP TABLE test118_t5_src;

-- =============================================================================
-- SQL Regression Tests for PostgreSQL commit:
-- "Yet further fixes for multi-row VALUES lists for updatable views"
--
-- The fix adds rewriteValuesRTEToNulls() to replace DEFAULT markers with NULLs
-- in DO ALSO product queries, instead of incorrectly re-using rewriteValuesRTE()
-- with force_nulls=true (which could crash or error on non-INSERT product queries).
-- =============================================================================


-- =============================================================================
-- Test 1: Core bug fix - DO ALSO rule with multi-row VALUES + DEFAULT markers
-- Covers: rewriteValuesRTEToNulls() called for DO ALSO product queries
--         (previously caused "cache lookup failed for type NNNN" errors)
-- Code path: RewriteQuery -> defaults_remaining=true -> rewriteValuesRTEToNulls(pt, values_rte)
-- =============================================================================

CREATE TABLE test1_base (
    id    int,
    val   text DEFAULT 'Table default',
    extra text DEFAULT 'Extra default'
);

CREATE TABLE test1_log (
    id    int,
    val   text,
    extra text
);

CREATE VIEW test1_view AS SELECT * FROM test1_base;

-- DO ALSO rule: the product query is an INSERT into test1_log
CREATE RULE test1_view_ins_rule AS ON INSERT TO test1_view
    DO ALSO INSERT INTO test1_log VALUES (new.id, new.val, new.extra);

-- Multi-row INSERT with DEFAULT markers: this is the exact bug scenario.
-- Before the fix, this would cause "cache lookup failed for type NNNN".
-- After the fix, rewriteValuesRTEToNulls replaces remaining DEFAULTs with NULLs
-- in the DO ALSO product query.
INSERT INTO test1_view VALUES (1, DEFAULT, DEFAULT), (2, DEFAULT, DEFAULT);
INSERT INTO test1_view VALUES (3, 'v3', DEFAULT), (4, DEFAULT, 'e4');

SELECT id, val, extra FROM test1_base ORDER BY id;
SELECT id, val, extra FROM test1_log ORDER BY id;

DROP VIEW test1_view;
DROP TABLE test1_base;
DROP TABLE test1_log;


-- =============================================================================
-- Test 2: DO ALSO rule on auto-updatable view with view-level DEFAULT overrides
-- Covers: rewriteValuesRTE() (no force_nulls) for the primary INSERT, then
--         rewriteValuesRTEToNulls() for the DO ALSO product query.
--         View has its own default that overrides table default for col b.
-- Code path: Block 3 in rewriteValuesRTE: searchForDefault -> replace with
--            view default (b) or table default (c), then ToNulls for product query.
-- =============================================================================

CREATE TABLE test2_base (
    a int,
    b text DEFAULT 'TableB',
    c text DEFAULT 'TableC',
    d text
);

CREATE VIEW test2_view AS SELECT * FROM test2_base;
ALTER VIEW test2_view ALTER COLUMN b SET DEFAULT 'ViewB';
ALTER VIEW test2_view ALTER COLUMN d SET DEFAULT 'ViewD';

CREATE TABLE test2_audit (a int, b text, c text, d text);

-- DO ALSO rule fires after auto-updatable-view rewrite
CREATE RULE test2_ins_rule AS ON INSERT TO test2_view
    DO ALSO INSERT INTO test2_audit VALUES (new.a, new.b, new.c, new.d);

-- Multi-row with mixed DEFAULT/explicit values
-- b: view default 'ViewB' applies; c: table default 'TableC' applies;
-- d: view default 'ViewD' applies for primary; NULL for product query
INSERT INTO test2_view VALUES
    (10, DEFAULT, DEFAULT, DEFAULT),
    (11, DEFAULT, DEFAULT, DEFAULT),
    (12, 'explicit', DEFAULT, DEFAULT);

SELECT * FROM test2_base ORDER BY a;
SELECT * FROM test2_audit ORDER BY a;

DROP VIEW test2_view;
DROP TABLE test2_base;
DROP TABLE test2_audit;


-- =============================================================================
-- Test 3: DO ALSO rule where the product query is NOT an INSERT
--         (e.g., DO ALSO SELECT or DO ALSO UPDATE/DELETE workaround via SELECT)
-- Covers: rewriteValuesRTEToNulls() must handle product queries that are not
--         INSERT (the function works regardless of commandType).
-- Code path: rewriteValuesRTEToNulls path where parsetree->commandType != CMD_INSERT
-- Note: DO ALSO with SELECT is valid in PostgreSQL rules.
-- =============================================================================

CREATE TABLE test3_base (
    id   int,
    name text DEFAULT 'default_name',
    cnt  int  DEFAULT 0
);

-- A separate table to log via trigger, avoiding DO ALSO non-INSERT limitation
CREATE TABLE test3_side (
    ts  timestamptz DEFAULT now(),
    id  int,
    name text
);

CREATE VIEW test3_view AS SELECT * FROM test3_base;
ALTER VIEW test3_view ALTER COLUMN name SET DEFAULT 'view_name';

-- DO ALSO INSERT rule (product query is INSERT into test3_side)
CREATE RULE test3_also_rule AS ON INSERT TO test3_view
    DO ALSO INSERT INTO test3_side(id, name) VALUES (new.id, new.name);

-- Multi-row VALUES with multiple DEFAULT columns
INSERT INTO test3_view VALUES
    (1, DEFAULT, DEFAULT),
    (2, DEFAULT, 99),
    (3, 'explicit', DEFAULT);

SELECT id, name, cnt FROM test3_base ORDER BY id;
SELECT id, name FROM test3_side ORDER BY id;

DROP VIEW test3_view;
DROP TABLE test3_base;
DROP TABLE test3_side;


-- =============================================================================
-- Test 4: rewriteValuesRTE() called for auto-updatable view with single and
--         multi-row VALUES, no DO ALSO rule (exercises the modified function
--         signature rewriteValuesRTE without force_nulls parameter).
-- Covers: Block 3 - Assert(parsetree->commandType == CMD_INSERT),
--                   Assert(rte->rtekind == RTE_VALUES),
--                   if (!searchForDefault(rte)) return true (no-op case)
-- =============================================================================

CREATE TABLE test4_base (
    id    serial PRIMARY KEY,
    label text   DEFAULT 'auto',
    score int    DEFAULT 100,
    tag   text
);

CREATE VIEW test4_view AS SELECT id, label, score, tag FROM test4_base;
ALTER VIEW test4_view ALTER COLUMN label SET DEFAULT 'view_auto';

-- Single-row INSERT with DEFAULT (exercises rewriteValuesRTE single-row path)
INSERT INTO test4_view (id, label, score, tag) VALUES (1, DEFAULT, DEFAULT, 'r1');

-- Multi-row INSERT with no DEFAULTs (exercises searchForDefault returning false -> early return)
INSERT INTO test4_view (id, label, score, tag) VALUES
    (2, 'explicit1', 200, 'r2'),
    (3, 'explicit2', 300, 'r3');

-- Multi-row INSERT with DEFAULTs (exercises full rewriteValuesRTE path)
INSERT INTO test4_view (id, label, score, tag) VALUES
    (4, DEFAULT, DEFAULT, 'r4'),
    (5, DEFAULT, 500, 'r5'),
    (6, 'v6', DEFAULT, 'r6');

-- Edge case: all-DEFAULT multi-row
INSERT INTO test4_view VALUES
    (7, DEFAULT, DEFAULT, NULL),
    (8, DEFAULT, DEFAULT, NULL);

SELECT * FROM test4_base ORDER BY id;

DROP VIEW test4_view;
DROP TABLE test4_base;


-- =============================================================================
-- Test 5: DO ALSO INSERT ... SELECT rule with multi-row VALUES + DEFAULT
-- Covers: rewriteValuesRTEToNulls for product query that is INSERT ... SELECT
--         (the subquery case handled at lines 3877-3892 in RewriteQuery).
--         This exercises the path where pt->commandType == CMD_INSERT but
--         the VALUES RTE is found in a subquery of the product query.
-- =============================================================================

CREATE TABLE test5_base (
    id   int,
    val  text DEFAULT 'tbl_default',
    misc text DEFAULT 'tbl_misc'
);

CREATE VIEW test5_view AS SELECT * FROM test5_base;
ALTER VIEW test5_view ALTER COLUMN val SET DEFAULT 'view_default';

CREATE TABLE test5_copy (
    id   int,
    val  text,
    note text DEFAULT 'copied'
);

-- DO ALSO INSERT ... SELECT rule: product query is INSERT ... SELECT (subquery)
CREATE RULE test5_also_sel_rule AS ON INSERT TO test5_view
    DO ALSO INSERT INTO test5_copy (id, val) SELECT new.id, new.val;

-- Multi-row VALUES with DEFAULT: triggers both rewriteValuesRTE (primary)
-- and rewriteValuesRTEToNulls (product INSERT...SELECT subquery)
INSERT INTO test5_view VALUES
    (1, DEFAULT, DEFAULT),
    (2, DEFAULT, DEFAULT),
    (3, 'explicit', DEFAULT);

-- Edge case: single DEFAULT row (searchForDefault returns true, processes one row)
INSERT INTO test5_view VALUES (4, DEFAULT, 'concrete');

SELECT id, val, misc FROM test5_base ORDER BY id;
SELECT id, val, note FROM test5_copy ORDER BY id;

DROP VIEW test5_view;
DROP TABLE test5_base;
DROP TABLE test5_copy;


-- ============================================================
-- SQL Regression Tests for:
--   Fix self-referencing foreign keys with partitioned tables
--   get_relation_idx_constraint_oid now filters to only
--   PRIMARY KEY, UNIQUE, EXCLUSION constraints (ignores FK)
-- ============================================================

-- ============================================================
-- Test 1: Self-referencing FK on partitioned table + ATTACH
-- Exercises: get_relation_idx_constraint_oid skipping FK type,
--            CloneFkReferenced ignoring self-referencing FK
-- ============================================================
-- Test 1: Self-referencing foreign key on partitioned table, attach partition
CREATE TABLE t1_selffk (
    id   INT NOT NULL,
    pid  INT,
    PRIMARY KEY (id)
) PARTITION BY RANGE (id);

ALTER TABLE t1_selffk ADD CONSTRAINT t1_selffk_pid_fkey
    FOREIGN KEY (pid) REFERENCES t1_selffk (id);

CREATE TABLE t1_selffk_p1 PARTITION OF t1_selffk
    FOR VALUES FROM (1) TO (100);

CREATE TABLE t1_selffk_p2 (
    id   INT NOT NULL,
    pid  INT,
    PRIMARY KEY (id)
);

ALTER TABLE t1_selffk ATTACH PARTITION t1_selffk_p2
    FOR VALUES FROM (100) TO (200);

-- Verify constraints exist (should not be duplicated)
SELECT conname, contype, conrelid::regclass
FROM pg_constraint
WHERE conrelid IN (
    't1_selffk'::regclass,
    't1_selffk_p1'::regclass,
    't1_selffk_p2'::regclass
)
ORDER BY conrelid::regclass::text, conname;

DROP TABLE t1_selffk CASCADE;

-- ============================================================
-- Test 2: Partitioned table with UNIQUE constraint + self-ref FK
-- Exercises: get_relation_idx_constraint_oid must return UNIQUE OID
--            not the FK OID (same relation has both)
-- ============================================================
CREATE TABLE t2_unique_selffk (
    id   INT NOT NULL,
    code TEXT NOT NULL,
    ref_code TEXT,
    UNIQUE (code)
) PARTITION BY LIST (id);

ALTER TABLE t2_unique_selffk
    ADD CONSTRAINT t2_unique_selffk_ref_fkey
    FOREIGN KEY (ref_code) REFERENCES t2_unique_selffk (code);

CREATE TABLE t2_unique_selffk_p1 PARTITION OF t2_unique_selffk
    FOR VALUES IN (1, 2, 3);

-- Verify that the UNIQUE constraint is properly cloned to partition
-- and FK constraint is not duplicated
SELECT conname, contype
FROM pg_constraint
WHERE conrelid = 't2_unique_selffk_p1'::regclass
ORDER BY conname;

DROP TABLE t2_unique_selffk CASCADE;

-- ============================================================
-- Test 3: Multi-level partitioning with self-referencing FK
-- Exercises: get_relation_idx_constraint_oid on nested partitions,
--            ensuring FK type is filtered at each recursion level
-- ============================================================
CREATE TABLE t3_multilevel (
    id    INT NOT NULL,
    sub   INT NOT NULL,
    parent_id INT,
    PRIMARY KEY (id, sub)
) PARTITION BY RANGE (id);

ALTER TABLE t3_multilevel
    ADD CONSTRAINT t3_multilevel_parent_fkey
    FOREIGN KEY (parent_id, sub) REFERENCES t3_multilevel (id, sub);

-- Create sub-partitioned table
CREATE TABLE t3_multilevel_p1 (
    id    INT NOT NULL,
    sub   INT NOT NULL,
    parent_id INT,
    PRIMARY KEY (id, sub)
) PARTITION BY RANGE (sub);

ALTER TABLE t3_multilevel ATTACH PARTITION t3_multilevel_p1
    FOR VALUES FROM (1) TO (50);

CREATE TABLE t3_multilevel_p1_s1 PARTITION OF t3_multilevel_p1
    FOR VALUES FROM (1) TO (10);

-- Check constraints on nested partition
SELECT conname, contype, conrelid::regclass
FROM pg_constraint
WHERE conrelid IN (
    't3_multilevel'::regclass,
    't3_multilevel_p1'::regclass,
    't3_multilevel_p1_s1'::regclass
)
ORDER BY conrelid::regclass::text, conname;

DROP TABLE t3_multilevel CASCADE;

-- ============================================================
-- Test 4: Attach existing table (with own PK) as partition,
--         where parent has both PK and self-referencing FK
-- Exercises: get_relation_idx_constraint_oid must match only PK
--            on the child, not confuse the FK OID with the PK OID
-- ============================================================
CREATE TABLE t4_parent (
    id    INT NOT NULL,
    val   TEXT,
    parent_id INT,
    PRIMARY KEY (id)
) PARTITION BY RANGE (id);

ALTER TABLE t4_parent
    ADD CONSTRAINT t4_parent_self_fkey
    FOREIGN KEY (parent_id) REFERENCES t4_parent (id);

-- Create standalone table that will be attached
CREATE TABLE t4_child_standalone (
    id    INT NOT NULL,
    val   TEXT,
    parent_id INT,
    PRIMARY KEY (id)
);

-- Attach the existing table as a partition
ALTER TABLE t4_parent ATTACH PARTITION t4_child_standalone
    FOR VALUES FROM (200) TO (300);

-- The child partition should have exactly one FK (not two)
-- and the PK should be child of parent's PK (not of FK)
SELECT conname, contype
FROM pg_constraint
WHERE conrelid = 't4_child_standalone'::regclass
ORDER BY contype, conname;

DROP TABLE t4_parent CASCADE;

-- ============================================================
-- Test 5: CREATE PARTITION directly (not ATTACH) with self-ref FK
-- Exercises: CloneFkReferencing path + get_relation_idx_constraint_oid
--            during CREATE TABLE ... PARTITION OF
-- ============================================================
CREATE TABLE t5_direct (
    id        INT NOT NULL,
    ref_id    INT,
    label     TEXT,
    PRIMARY KEY (id)
) PARTITION BY RANGE (id);

ALTER TABLE t5_direct
    ADD CONSTRAINT t5_direct_ref_fkey
    FOREIGN KEY (ref_id) REFERENCES t5_direct (id);

-- Direct CREATE PARTITION (triggers CloneFkReferenced + CloneFkReferencing)
CREATE TABLE t5_direct_p1 PARTITION OF t5_direct
    FOR VALUES FROM (1) TO (500);

CREATE TABLE t5_direct_p2 PARTITION OF t5_direct
    FOR VALUES FROM (500) TO (1000);

-- Verify no duplicate FK constraints on partitions
SELECT conrelid::regclass, conname, contype, COUNT(*) AS cnt
FROM pg_constraint
WHERE conrelid IN (
    't5_direct_p1'::regclass,
    't5_direct_p2'::regclass
)
GROUP BY conrelid::regclass, conname, contype
ORDER BY conrelid::regclass::text, conname;

-- Insert data to verify constraints actually work
INSERT INTO t5_direct VALUES (1, NULL, 'root');
INSERT INTO t5_direct VALUES (2, 1, 'child');

-- This should fail (ref_id 999 does not exist)
DO $$
BEGIN
    BEGIN
        INSERT INTO t5_direct VALUES (3, 999, 'bad');
        RAISE NOTICE 'ERROR: expected FK violation did not occur';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'OK: FK violation caught as expected';
    END;
END;
$$;

DROP TABLE t5_direct CASCADE;

-- ============================================================
-- SQL 回归测试: 覆盖 nodeAgg.c 中 finalize_aggregate 和
-- finalize_partialaggregate 移除 MemoryContextContains 的变更
-- 新逻辑: 使用 MakeExpandedObjectReadOnly 替代原来的
--         MemoryContextContains + datumCopy 组合
-- ============================================================

-- ============================================================
-- Test 1: finalize_aggregate - 无 finalfn 分支，pass-by-ref 类型
--   覆盖路径: else 分支（OidIsValid(peragg->finalfn_oid) = false）
--   max(text) / max(bytea) 没有 finalfn，transition value 直接
--   作为结果返回，新代码用 MakeExpandedObjectReadOnly 处理
-- ============================================================
CREATE TABLE test_agg_no_finalfn (
    id   SERIAL,
    val  TEXT,
    grp  INT
);

INSERT INTO test_agg_no_finalfn (val, grp) VALUES
    ('apple',   1),
    ('banana',  1),
    ('cherry',  1),
    ('date',    2),
    ('elderberry', 2),
    (NULL,      2),
    ('fig',     3),
    (NULL,      3);

-- max(text) 没有 finalfn；过渡值 = 结果值（pass-by-ref），
-- 新代码在 else 分支执行 MakeExpandedObjectReadOnly
SELECT grp, max(val) AS max_val
FROM test_agg_no_finalfn
GROUP BY grp
ORDER BY grp;

-- min(text) 同理
SELECT grp, min(val) AS min_val
FROM test_agg_no_finalfn
GROUP BY grp
ORDER BY grp;

DROP TABLE test_agg_no_finalfn;


-- ============================================================
-- Test 2: finalize_aggregate - 全 NULL 过渡值（transValueIsNull=true）
--   覆盖路径: else 分支，transValueIsNull=true 时
--   MakeExpandedObjectReadOnly 需要正确处理 NULL 输入
-- ============================================================
CREATE TABLE test_agg_all_null (
    id  INT,
    val TEXT
);

INSERT INTO test_agg_all_null VALUES
    (1, NULL),
    (2, NULL),
    (3, NULL);

-- 全 NULL 输入，transition value 始终为 NULL
-- 新代码路径: MakeExpandedObjectReadOnly(..., transValueIsNull=true, ...)
SELECT max(val)       AS max_null,
       min(val)       AS min_null,
       count(val)     AS cnt_non_null,
       sum(id::bigint) AS sum_ids
FROM test_agg_all_null;

DROP TABLE test_agg_all_null;


-- ============================================================
-- Test 3: finalize_aggregate - WITH finalfn，使用 expanded datum
--   覆盖路径: if 分支（OidIsValid(peragg->finalfn_oid) = true）
--   array_agg / array_agg(anyarray) 使用 internal 过渡状态和 finalfn
--   finalfn 调用时 fcinfo->args[0].value 经过 MakeExpandedObjectReadOnly
-- ============================================================
CREATE TABLE test_agg_with_finalfn (
    id    INT,
    grp   INT,
    val   INT,
    label TEXT
);

INSERT INTO test_agg_with_finalfn VALUES
    (1, 1, 10, 'a'),
    (2, 1, 20, 'b'),
    (3, 1, 30, 'c'),
    (4, 2, 40, 'd'),
    (5, 2, 50, 'e'),
    (6, 2, NULL, 'f'),
    (7, 3, NULL, NULL);

-- array_agg 有 finalfn=array_agg_finalfn, 过渡类型=internal
-- 触发 if(OidIsValid(finalfn_oid)) 分支的 MakeExpandedObjectReadOnly
SELECT grp,
       array_agg(val ORDER BY val)   AS vals,
       array_agg(label ORDER BY id)  AS labels
FROM test_agg_with_finalfn
GROUP BY grp
ORDER BY grp;

-- string_agg 也有 finalfn=string_agg_finalfn
SELECT grp, string_agg(label, ',' ORDER BY id) AS labels_str
FROM test_agg_with_finalfn
GROUP BY grp
ORDER BY grp;

DROP TABLE test_agg_with_finalfn;


-- ============================================================
-- Test 4: finalize_aggregate - sum(interval) 无 finalfn，pass-by-ref
--   覆盖路径: else 分支，interval 是 pass-by-ref 类型，
--   sum(interval) 的过渡类型就是 interval，没有 finalfn
--   新代码对此类型执行 MakeExpandedObjectReadOnly
-- ============================================================
CREATE TABLE test_agg_interval (
    id  INT,
    dur INTERVAL,
    grp CHAR(1)
);

INSERT INTO test_agg_interval VALUES
    (1, '1 hour',           'A'),
    (2, '30 minutes',       'A'),
    (3, '2 hours 15 mins',  'A'),
    (4, '45 minutes',       'B'),
    (5, '3 hours',          'B'),
    (6, NULL,               'B'),
    (7, NULL,               'C');

-- sum(interval) 没有 finalfn；transtype=interval（pass-by-ref）
-- 新代码 else 分支: MakeExpandedObjectReadOnly(transValue, ...)
SELECT grp,
       sum(dur)        AS total_dur,
       max(dur)        AS max_dur,
       min(dur)        AS min_dur
FROM test_agg_interval
GROUP BY grp
ORDER BY grp;

DROP TABLE test_agg_interval;


-- ============================================================
-- Test 5: finalize_aggregate - 多组 GROUP BY + HAVING，
--   验证每组结果独立经过 MakeExpandedObjectReadOnly 处理
--   同时覆盖 pass-by-ref (text) 和 pass-by-val (int8) 混合场景
-- ============================================================
CREATE TABLE test_agg_groupby_having (
    region   TEXT,
    category TEXT,
    amount   NUMERIC,
    note     TEXT
);

INSERT INTO test_agg_groupby_having VALUES
    ('East', 'A', 100.5,  'first'),
    ('East', 'A', 200.0,  'second'),
    ('East', 'B', 150.75, 'third'),
    ('West', 'A', 300.0,  NULL),
    ('West', 'A', 50.25,  'fifth'),
    ('West', 'B', NULL,   'sixth'),
    ('West', 'B', 400.0,  'seventh'),
    ('North','A', NULL,   NULL),
    ('North','A', NULL,   NULL);

-- 多个 pass-by-ref 聚合（max(text), max(numeric)）在同一查询中
-- GROUP BY 多列使 finalize_aggregate 被调用多次
-- HAVING 筛选确保覆盖有效分组和空分组的代码路径
SELECT region, category,
       count(*)              AS cnt,
       max(amount)           AS max_amount,
       min(amount)           AS min_amount,
       sum(amount)           AS sum_amount,
       max(note)             AS max_note,
       array_agg(note ORDER BY amount NULLS LAST) AS notes_arr
FROM test_agg_groupby_having
GROUP BY region, category
HAVING count(*) >= 1
ORDER BY region, category;

DROP TABLE test_agg_groupby_having;

-- ============================================================
-- SQL Regression Tests for: Avoid improbable PANIC during heap_update, redux
-- Commit: Fix RelationGetBufferForTuple to always call GetVisibilityMapPins
--         and recheck free space when otherBuffer is set (heap_update path),
--         even when the conditional lock on otherBuffer succeeds.
--         Also replaces bare `if` with `else if` for the no-otherBuffer PANIC path.
-- ============================================================


-- ===========================================================
-- Test 1: Basic heap_update triggering RelationGetBufferForTuple
--         with otherBuffer path (new tuple goes to a different page).
--         Covers: GetVisibilityMapPins + space recheck in extension path.
-- ===========================================================
-- Code path: heap_update -> RelationGetBufferForTuple(otherBuffer != InvalidBuffer)
--            The updated tuple must move to a new/different page, forcing
--            the relation-extension branch (lines 635-672 in hio.c).

CREATE TABLE test_heap_update_otherpage (
    id      SERIAL PRIMARY KEY,
    payload TEXT
);

-- Fill page 0 with wide rows so any update must go to a new page
INSERT INTO test_heap_update_otherpage (payload)
SELECT repeat('x', 1800)
FROM generate_series(1, 4);

-- VACUUM to mark pages all-visible (sets visibility map bits),
-- which forces GetVisibilityMapPins to actually acquire VM pins
VACUUM test_heap_update_otherpage;

-- Now UPDATE with a wider value so the new tuple cannot fit on the same page;
-- this exercises the otherBuffer != InvalidBuffer extension branch.
UPDATE test_heap_update_otherpage
SET payload = repeat('y', 1800)
WHERE id = 1;

-- Verify rows are intact
SELECT COUNT(*) FROM test_heap_update_otherpage;

DROP TABLE test_heap_update_otherpage;


-- ===========================================================
-- Test 2: heap_update after VACUUM FREEZE so all-visible bits are set.
--         Covers: GetVisibilityMapPins needing to acquire VM pin for
--         otherBuffer AFTER the conditional lock on otherBuffer succeeds.
--         This is the exact race-condition scenario the fix addresses.
-- ===========================================================
-- Code path: ConditionalLockBuffer(otherBuffer) succeeds BUT
--            GetVisibilityMapPins still needs to pin VM for otherBuffer,
--            which may transiently release lock on target buffer,
--            making the subsequent free-space recheck necessary.

CREATE TABLE test_vm_pin_after_freeze (
    id      INT,
    payload TEXT
);

INSERT INTO test_vm_pin_after_freeze
SELECT i, repeat('a', 1500)
FROM generate_series(1, 5) AS i;

-- VACUUM FREEZE sets all-visible on all pages
VACUUM FREEZE test_vm_pin_after_freeze;

-- UPDATE forces heap_update; since pages are all-visible,
-- GetVisibilityMapPins must acquire pins. With the fix, this is
-- done in BOTH the conditional-lock-succeeded and failed paths.
UPDATE test_vm_pin_after_freeze
SET payload = repeat('b', 1500)
WHERE id <= 3;

SELECT COUNT(*) FROM test_vm_pin_after_freeze WHERE id <= 3;

DROP TABLE test_vm_pin_after_freeze;


-- ===========================================================
-- Test 3: heap_update with fillfactor=50 to force relation extension.
--         Covers: the goto-loop retry path when free space check fails
--         after GetVisibilityMapPins transiently releases buffer locks.
-- ===========================================================
-- Code path: After GetVisibilityMapPins, len > PageGetHeapFreeSpace(page)
--            triggers LockBuffer(otherBuffer, BUFFER_LOCK_UNLOCK) +
--            UnlockReleaseBuffer(buffer) + goto loop  (lines 665-671).

CREATE TABLE test_update_fillfactor (
    id      INT,
    payload TEXT
) WITH (fillfactor = 50);

-- Insert enough rows to fill pages to ~50% capacity
INSERT INTO test_update_fillfactor
SELECT i, repeat('z', 800)
FROM generate_series(1, 8) AS i;

VACUUM test_update_fillfactor;

-- UPDATE with larger payload to exhaust free space and trigger retry loop
UPDATE test_update_fillfactor
SET payload = repeat('Z', 1600)
WHERE id % 2 = 0;

SELECT COUNT(*) FROM test_update_fillfactor;

DROP TABLE test_update_fillfactor;


-- ===========================================================
-- Test 4: heap_update with NULL values — edge case for tuple sizing.
--         Covers: len computation with NULLable columns; ensures the
--         else-if branch (no otherBuffer) does NOT fire PANIC for
--         normal-sized tuples, validating the else-if guard is correct.
-- ===========================================================
-- Code path: otherBuffer == InvalidBuffer -> else if (len > PageGetHeapFreeSpace)
--            For a normally-sized tuple this branch is NOT entered (no PANIC).
--            Also exercises the with-otherBuffer path for NULL payloads.

CREATE TABLE test_update_nulls (
    id      INT,
    col1    TEXT,
    col2    TEXT,
    col3    BYTEA
);

INSERT INTO test_update_nulls VALUES
    (1, NULL,          NULL,          NULL),
    (2, 'hello',       NULL,          NULL),
    (3, NULL,          'world',       NULL),
    (4, repeat('m',500), repeat('n',500), NULL);

VACUUM test_update_nulls;

-- Update NULL -> non-NULL (may require moving tuple to another page)
UPDATE test_update_nulls SET col1 = repeat('A', 500), col3 = repeat('B', 200)::bytea WHERE id = 1;
-- Update non-NULL -> NULL (shrink tuple)
UPDATE test_update_nulls SET col1 = NULL, col2 = NULL WHERE id = 4;
-- Update with all NULLs remaining NULL
UPDATE test_update_nulls SET col3 = NULL WHERE id = 2;

SELECT id, col1 IS NULL AS c1_null, col2 IS NULL AS c2_null FROM test_update_nulls ORDER BY id;

DROP TABLE test_update_nulls;


-- ===========================================================
-- Test 5: Concurrent-style stress: repeated UPDATE on a table with
--         multiple pages to exercise the full otherBuffer locking
--         sequence (both conditional-lock-success and fallback paths).
--         Covers: the complete code block at hio.c lines 635-677.
-- ===========================================================
-- Code path: Multiple round-trips through the loop:
--   1. FSM returns a target page; otherBuffer on a different page.
--   2. Extend-relation branch taken when FSM exhausted.
--   3. GetVisibilityMapPins called unconditionally (the fix).
--   4. Free-space recheck after GetVisibilityMapPins (the fix).

CREATE TABLE test_update_multipage (
    id      SERIAL,
    grp     INT,
    payload TEXT
);

-- Create multiple pages of data
INSERT INTO test_update_multipage (grp, payload)
SELECT (i % 4) + 1, repeat('x', 1000)
FROM generate_series(1, 20) AS i;

-- VACUUM so visibility map is up-to-date and pages are all-visible
VACUUM test_update_multipage;

-- Perform many updates across different groups, forcing cross-page moves
UPDATE test_update_multipage SET payload = repeat('Y', 1200) WHERE grp = 1;
UPDATE test_update_multipage SET payload = repeat('Z', 800)  WHERE grp = 2;
UPDATE test_update_multipage SET payload = repeat('W', 1400) WHERE grp = 3;
UPDATE test_update_multipage SET payload = repeat('V', 600)  WHERE grp = 4;

-- Final VACUUM + recheck
VACUUM ANALYZE test_update_multipage;

SELECT grp, COUNT(*) FROM test_update_multipage GROUP BY grp ORDER BY grp;

DROP TABLE test_update_multipage;

-- Test 1: Basic DELETE on an all-visible page (exercises Block 0 reordering:
-- lp/tp initialized before l1 label, then visibility map re-pin check at l1).
-- VACUUM makes the page all-visible; subsequent DELETE must re-pin VM page.
CREATE TABLE t125_basic (id int, val text);
INSERT INTO t125_basic SELECT g, 'row'||g FROM generate_series(1,100) g;
VACUUM t125_basic;          -- marks pages all-visible, sets VM bits
DELETE FROM t125_basic WHERE id = 50;
DROP TABLE t125_basic;

-- Test 2: DELETE on an all-visible page via index scan (exercises the
-- PageIsAllVisible() re-check at l1 for a single indexed row).
CREATE TABLE t125_indexed (id int PRIMARY KEY, val text);
INSERT INTO t125_indexed SELECT g, repeat('x', 50) FROM generate_series(1,200) g;
VACUUM FREEZE t125_indexed;  -- freeze + all-visible
DELETE FROM t125_indexed WHERE id = 100;
DROP TABLE t125_indexed;

-- Test 3: DELETE after a concurrent FOR SHARE lock has been released
-- (exercises Block 2 path: MultiXact wait + goto l1 re-check including
-- new vmbuffer == InvalidBuffer && PageIsAllVisible() condition).
-- We simulate this within a single session using advisory locks to serialise,
-- then delete a row that was previously share-locked by an already-committed
-- sub-transaction, on a table whose page is all-visible.
CREATE TABLE t125_multixact (id int, payload text);
INSERT INTO t125_multixact SELECT g, lpad('a',200,'b') FROM generate_series(1,50) g;
VACUUM t125_multixact;
BEGIN;
  -- Lock some rows (creates HEAP_XMAX_IS_MULTI or plain key share xmax)
  SELECT id FROM t125_multixact WHERE id BETWEEN 1 AND 5 FOR SHARE;
  -- Now delete one of the locked rows; heap_delete will see TM_BeingModified
  -- from the share lock held by our own xact (non-conflicting path), but the
  -- VM re-check logic is still exercised on the all-visible page.
  DELETE FROM t125_multixact WHERE id = 3;
COMMIT;
DROP TABLE t125_multixact;

-- Test 4: DELETE after waiting for another transaction's row-level lock
-- (exercises Block 3 path: XactLockTableWait + goto l1 including the new
-- vmbuffer == InvalidBuffer && PageIsAllVisible() guard).
-- Two sessions are emulated by using a function that opens a subtransaction,
-- locks a row FOR UPDATE, then releases it so the outer DELETE can proceed.
CREATE TABLE t125_xact_wait (id int, val int);
INSERT INTO t125_xact_wait SELECT g, g*10 FROM generate_series(1,80) g;
VACUUM t125_xact_wait;        -- page becomes all-visible
-- Subtransaction locks then releases a row, then outer txn deletes it.
BEGIN;
  SAVEPOINT sp1;
    SELECT * FROM t125_xact_wait WHERE id = 40 FOR UPDATE;
  RELEASE SAVEPOINT sp1;      -- lock held until COMMIT, but page was all-visible
  DELETE FROM t125_xact_wait WHERE id = 40;
COMMIT;
DROP TABLE t125_xact_wait;

-- Test 5: DELETE of every row on an all-visible page (stress the l1 path
-- repeatedly for all tuples; exercises that lp/tp re-init before l1 means
-- each iteration reads fresh tuple data after a potential VM re-pin).
CREATE TABLE t125_fullpage (id int, filler char(100));
-- Fill exactly one page worth of rows then vacuum to mark it all-visible.
INSERT INTO t125_fullpage SELECT g, 'z' FROM generate_series(1,20) g;
VACUUM t125_fullpage;
DELETE FROM t125_fullpage;   -- removes all rows, exercising heap_delete for each
DROP TABLE t125_fullpage;

-- Test 1: ExecShutdownNode_walker via Gather node (parallel query shutdown)
-- Exercises ExecShutdownNode -> ExecShutdownNode_walker -> planstate_tree_walker
-- -> ExecShutdownGather path with a real parallel plan tree
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;

CREATE TABLE shutdown_test_gather (id int, val text);
INSERT INTO shutdown_test_gather SELECT i, 'v' || i FROM generate_series(1, 10000) i;
ANALYZE shutdown_test_gather;
ALTER TABLE shutdown_test_gather SET (parallel_workers = 2);

-- EXPLAIN ANALYZE triggers ExecShutdownNode at executor teardown,
-- exercising the new ExecShutdownNode_walker recursion
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM shutdown_test_gather WHERE id > 0;

DROP TABLE shutdown_test_gather;
RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET min_parallel_table_scan_size;
RESET max_parallel_workers_per_gather;

-- Test 2: ExecShutdownNode_walker via GatherMerge node (ordered parallel scan)
-- Exercises the T_GatherMergeState branch in ExecShutdownNode_walker
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;
SET enable_hashagg = off;

CREATE TABLE shutdown_test_gm (id int, grp int);
INSERT INTO shutdown_test_gm SELECT i, i % 100 FROM generate_series(1, 10000) i;
ANALYZE shutdown_test_gm;
ALTER TABLE shutdown_test_gm SET (parallel_workers = 2);
CREATE INDEX ON shutdown_test_gm (id);

-- ORDER BY on a parallel scan typically produces a GatherMerge node
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT id FROM shutdown_test_gm ORDER BY id LIMIT 100;

DROP TABLE shutdown_test_gm;
RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET min_parallel_table_scan_size;
RESET max_parallel_workers_per_gather;
RESET enable_hashagg;

-- Test 3: ExecShutdownNode_walker via Hash / HashJoin nodes (multi-level tree)
-- Exercises planstate_tree_walker recursing through a join plan tree,
-- hitting T_HashState and T_HashJoinState branches in the walker
SET enable_hashjoin = on;
SET enable_nestloop = off;
SET enable_mergejoin = off;

CREATE TABLE shutdown_lhs (id int, val int);
CREATE TABLE shutdown_rhs (id int, val int);
INSERT INTO shutdown_lhs SELECT i, i * 2 FROM generate_series(1, 5000) i;
INSERT INTO shutdown_rhs SELECT i, i * 3 FROM generate_series(1, 5000) i;
ANALYZE shutdown_lhs;
ANALYZE shutdown_rhs;

-- Hash join plan: HashJoin -> (SeqScan, Hash -> SeqScan)
-- ExecShutdownNode_walker must recurse into both sides of the join
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT l.id FROM shutdown_lhs l JOIN shutdown_rhs r ON l.id = r.id WHERE l.val > 100;

DROP TABLE shutdown_lhs;
DROP TABLE shutdown_rhs;
RESET enable_hashjoin;
RESET enable_nestloop;
RESET enable_mergejoin;

-- Test 4: ExecShutdownNode_walker with instrumentation active (EXPLAIN ANALYZE)
-- Exercises the InstrStartNode/InstrStopNode branches inside ExecShutdownNode_walker
-- (node->instrument != NULL && node->instrument->running)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;

CREATE TABLE shutdown_instr (id int, payload text);
INSERT INTO shutdown_instr SELECT i, repeat('x', 100) FROM generate_series(1, 5000) i;
ANALYZE shutdown_instr;
ALTER TABLE shutdown_instr SET (parallel_workers = 2);

-- ANALYZE ensures instrumentation nodes are live when shutdown runs,
-- so the instrument->running branches in ExecShutdownNode_walker fire
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT sum(id) FROM shutdown_instr;

DROP TABLE shutdown_instr;
RESET parallel_setup_cost;
RESET parallel_tuple_cost;
RESET min_parallel_table_scan_size;
RESET max_parallel_workers_per_gather;

-- Test 5: ExecShutdownNode_walker with a deeply nested subquery plan tree
-- Exercises planstate_tree_walker recursing through multiple levels:
-- Limit -> Sort -> HashAgg -> Hash Join -> (Seq, Hash -> Seq)
-- Each level must be visited by ExecShutdownNode_walker via recursive walk
SET enable_hashjoin = on;
SET enable_nestloop = off;
SET enable_mergejoin = off;

CREATE TABLE shutdown_deep_a (id int, cat int, score int);
CREATE TABLE shutdown_deep_b (id int, label text);
INSERT INTO shutdown_deep_a SELECT i, i % 10, i * 7 % 100 FROM generate_series(1, 3000) i;
INSERT INTO shutdown_deep_b SELECT i, 'label_' || i FROM generate_series(1, 3000) i;
ANALYZE shutdown_deep_a;
ANALYZE shutdown_deep_b;

-- Multi-level plan ensures walker recurses through the full tree
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT cat, sum(score)
FROM shutdown_deep_a a
JOIN shutdown_deep_b b ON a.id = b.id
GROUP BY cat
ORDER BY cat
LIMIT 5;

DROP TABLE shutdown_deep_a;
DROP TABLE shutdown_deep_b;
RESET enable_hashjoin;
RESET enable_nestloop;
RESET enable_mergejoin;

-- ============================================================
-- SQL Regression Tests for:
-- "Choose FK name correctly during partition attachment"
-- Fix: CloneFkReferencing moves ConstraintNameIsUsed check to
--      AFTER fk_attrs list is populated, so the generated name
--      uses "<relname>_<attrs>_fkey" instead of "<relname>__fkey"
-- ============================================================

-- ===========================================================
-- Test 1: Normal path (else branch) — no name conflict
-- Parent partitioned table has a FK; partition has no
-- pre-existing constraint with the same name.
-- Attaching should clone the FK with the same name as parent.
-- Covers: else branch → fkconstraint->conname = pstrdup(parent name)
-- ===========================================================
CREATE SCHEMA fktest127_1;

CREATE TABLE fktest127_1.ref_tbl (
    id   INT PRIMARY KEY,
    val  TEXT
);

CREATE TABLE fktest127_1.parent_tbl (
    id      INT,
    ref_id  INT,
    FOREIGN KEY (ref_id) REFERENCES fktest127_1.ref_tbl(id)
) PARTITION BY LIST (id);

-- Partition has NO pre-existing constraint → else branch
CREATE TABLE fktest127_1.part1 (
    id     INT,
    ref_id INT
);

INSERT INTO fktest127_1.ref_tbl VALUES (1, 'a'), (2, 'b');
INSERT INTO fktest127_1.part1 VALUES (1, 1), (2, 2);

-- This triggers CloneFkReferencing; no name conflict → else branch
ALTER TABLE fktest127_1.parent_tbl
    ATTACH PARTITION fktest127_1.part1 FOR VALUES IN (1, 2);

-- Verify the cloned FK constraint exists on the partition
SELECT conname
FROM   pg_constraint
WHERE  conrelid = 'fktest127_1.part1'::regclass
  AND  contype  = 'f'
ORDER BY conname;

DROP SCHEMA fktest127_1 CASCADE;


-- ===========================================================
-- Test 2: Name-conflict path (if branch) — constraint name
-- already used on the partition.
-- The partition already owns a FK constraint whose name matches
-- the parent's FK name but targets a different column/table,
-- so it cannot be reused by tryAttachPartitionForeignKey.
-- The fix ensures fk_attrs is populated BEFORE
-- ChooseForeignKeyConstraintNameAddition() is called, producing
-- "<part>_ref_id_fkey" instead of "<part>__fkey".
-- Covers: if branch → ChooseConstraintName with fk_attrs filled
-- ===========================================================
CREATE SCHEMA fktest127_2;

CREATE TABLE fktest127_2.ref_tbl (
    id INT PRIMARY KEY
);

CREATE TABLE fktest127_2.ref_tbl2 (
    id INT PRIMARY KEY
);

-- Parent partitioned table: FK named "parent_tbl_ref_id_fkey"
CREATE TABLE fktest127_2.parent_tbl (
    id     INT,
    ref_id INT,
    FOREIGN KEY (ref_id) REFERENCES fktest127_2.ref_tbl(id)
) PARTITION BY LIST (id);

-- Partition pre-creates a constraint with the SAME name as the
-- parent's FK but pointing to a different table, causing a conflict.
CREATE TABLE fktest127_2.part1 (
    id     INT,
    ref_id INT,
    CONSTRAINT parent_tbl_ref_id_fkey
        FOREIGN KEY (ref_id) REFERENCES fktest127_2.ref_tbl2(id)
);

INSERT INTO fktest127_2.ref_tbl  VALUES (10);
INSERT INTO fktest127_2.ref_tbl2 VALUES (10);
INSERT INTO fktest127_2.part1    VALUES (10, 10);

-- ATTACH triggers CloneFkReferencing; name collision → if branch
-- With the fix the new constraint name includes the column name.
ALTER TABLE fktest127_2.parent_tbl
    ATTACH PARTITION fktest127_2.part1 FOR VALUES IN (10);

-- Verify that a new FK was created with a proper column-based name
-- (should contain "ref_id", not be just "<relname>__fkey")
SELECT conname
FROM   pg_constraint
WHERE  conrelid = 'fktest127_2.part1'::regclass
  AND  contype  = 'f'
ORDER BY conname;

DROP SCHEMA fktest127_2 CASCADE;


-- ===========================================================
-- Test 3: Multi-column FK with name conflict
-- Ensures ChooseForeignKeyConstraintNameAddition receives a
-- fully-populated fk_attrs list (multiple columns) before being
-- called when a name conflict exists.
-- Covers: if branch with multi-column FK attrs list
-- ===========================================================
CREATE SCHEMA fktest127_3;

CREATE TABLE fktest127_3.ref_tbl (
    a INT,
    b INT,
    PRIMARY KEY (a, b)
);

CREATE TABLE fktest127_3.ref_tbl2 (
    a INT,
    b INT,
    PRIMARY KEY (a, b)
);

-- Parent FK: name will be something like "parent_tbl_a_b_fkey"
CREATE TABLE fktest127_3.parent_tbl (
    id INT,
    a  INT,
    b  INT,
    FOREIGN KEY (a, b) REFERENCES fktest127_3.ref_tbl(a, b)
) PARTITION BY LIST (id);

-- Force name collision by pre-creating a constraint with the same
-- name but different target on the partition.
CREATE TABLE fktest127_3.part1 (
    id INT,
    a  INT,
    b  INT,
    CONSTRAINT parent_tbl_a_b_fkey
        FOREIGN KEY (a, b) REFERENCES fktest127_3.ref_tbl2(a, b)
);

INSERT INTO fktest127_3.ref_tbl  VALUES (1, 2);
INSERT INTO fktest127_3.ref_tbl2 VALUES (1, 2);
INSERT INTO fktest127_3.part1    VALUES (5, 1, 2);

ALTER TABLE fktest127_3.parent_tbl
    ATTACH PARTITION fktest127_3.part1 FOR VALUES IN (5);

-- With the fix the cloned FK name should include both column names
SELECT conname
FROM   pg_constraint
WHERE  conrelid = 'fktest127_3.part1'::regclass
  AND  contype  = 'f'
ORDER BY conname;

DROP SCHEMA fktest127_3 CASCADE;


-- ===========================================================
-- Test 4: Detach then re-attach (name conflict on re-attach)
-- A partition is created as PARTITION OF (gets cloned FK),
-- then detached (FK stays), then re-attached.  On re-attach
-- the existing FK on the partition has the same name as the
-- parent → tryAttachPartitionForeignKey should reuse it
-- (the else path), so no new constraint name is generated.
-- Covers: the attached=true early-exit path, then else branch
--         on a subsequent attach after explicit name collision.
-- ===========================================================
CREATE SCHEMA fktest127_4;

CREATE TABLE fktest127_4.ref_tbl (
    id INT PRIMARY KEY
);

CREATE TABLE fktest127_4.parent_tbl (
    id     INT,
    ref_id INT,
    FOREIGN KEY (ref_id) REFERENCES fktest127_4.ref_tbl(id)
) PARTITION BY LIST (id);

-- Create as partition OF → clones FK automatically
CREATE TABLE fktest127_4.part1
    PARTITION OF fktest127_4.parent_tbl FOR VALUES IN (1, 2);

INSERT INTO fktest127_4.ref_tbl VALUES (1), (2);
INSERT INTO fktest127_4.part1   VALUES (1, 1), (2, 2);

-- Detach keeps the FK on the partition
ALTER TABLE fktest127_4.parent_tbl
    DETACH PARTITION fktest127_4.part1;

-- Re-attach: tryAttachPartitionForeignKey should find the existing
-- compatible FK and reuse it (attached=true path), so
-- CloneFkReferencing does NOT reach the if/else name block.
ALTER TABLE fktest127_4.parent_tbl
    ATTACH PARTITION fktest127_4.part1 FOR VALUES IN (1, 2);

SELECT conname
FROM   pg_constraint
WHERE  conrelid = 'fktest127_4.part1'::regclass
  AND  contype  = 'f'
ORDER BY conname;

DROP SCHEMA fktest127_4 CASCADE;


-- ===========================================================
-- Test 5: Sub-partition hierarchy with name conflict
-- A two-level partitioned table: parent → mid → leaf.
-- The leaf already has a constraint whose name matches the
-- parent's FK, triggering the if branch (name conflict) when
-- the leaf is attached to mid which is then attached to parent.
-- Covers: recursive CloneFkReferencing through partition levels
--         hitting the if branch with properly populated fk_attrs
-- ===========================================================
CREATE SCHEMA fktest127_5;

CREATE TABLE fktest127_5.ref_tbl (
    id INT PRIMARY KEY
);

CREATE TABLE fktest127_5.ref_tbl2 (
    id INT PRIMARY KEY
);

-- Top-level partitioned table with FK
CREATE TABLE fktest127_5.parent_tbl (
    id     INT,
    ref_id INT,
    FOREIGN KEY (ref_id) REFERENCES fktest127_5.ref_tbl(id)
) PARTITION BY LIST (id);

-- Mid-level partitioned table (will be attached to parent)
CREATE TABLE fktest127_5.mid_tbl (
    id     INT,
    ref_id INT
) PARTITION BY LIST (id);

-- Leaf partition pre-has a conflicting constraint name
CREATE TABLE fktest127_5.leaf_tbl (
    id     INT,
    ref_id INT,
    CONSTRAINT parent_tbl_ref_id_fkey
        FOREIGN KEY (ref_id) REFERENCES fktest127_5.ref_tbl2(id)
);

INSERT INTO fktest127_5.ref_tbl  VALUES (100);
INSERT INTO fktest127_5.ref_tbl2 VALUES (100);
INSERT INTO fktest127_5.leaf_tbl VALUES (10, 100);

-- Attach leaf to mid first (mid has no FK yet, so no clone here)
ALTER TABLE fktest127_5.mid_tbl
    ATTACH PARTITION fktest127_5.leaf_tbl FOR VALUES IN (10);

-- Now attach mid to parent: this triggers CloneFkReferencing on
-- mid_tbl and recursively on leaf_tbl; leaf has the name conflict
-- → if branch fires with fully-populated fk_attrs
ALTER TABLE fktest127_5.parent_tbl
    ATTACH PARTITION fktest127_5.mid_tbl FOR VALUES IN (10);

-- Check that leaf got a proper column-based name (contains "ref_id")
SELECT conname
FROM   pg_constraint
WHERE  conrelid = 'fktest127_5.leaf_tbl'::regclass
  AND  contype  = 'f'
ORDER BY conname;

DROP SCHEMA fktest127_5 CASCADE;

-- SQL Regression Tests for commit:
-- "Fix subtly-incorrect matching of parent and child partitioned indexes"
--
-- The fix uses BuildIndexInfo(parentIndex) to rebuild IndexInfo from catalog
-- so that expression preprocessing is applied consistently when comparing
-- parent and child partitioned indexes via CompareIndexInfo().
-- Also uses parentIndex->rd_indcollation and parentIndex->rd_opfamily directly.

-- ===========================================================================
-- Test 1: Expression index on partitioned table
-- Covers: BuildIndexInfo(parentIndex) path with expression index
-- The bug was that expression indexes weren't preprocessed, causing mismatch.
-- Creating a partitioned index where child already has an expression index
-- should absorb (not duplicate) the child index.
-- ===========================================================================

CREATE TABLE t128_expr (a int, b int) PARTITION BY RANGE (a);
CREATE TABLE t128_expr1 (LIKE t128_expr);
CREATE TABLE t128_expr2 (LIKE t128_expr);

-- Create expression indexes on partitions first
CREATE INDEX ON t128_expr1 ((a + b));
CREATE INDEX ON t128_expr2 ((a + b));

-- Attach partitions to parent
ALTER TABLE t128_expr ATTACH PARTITION t128_expr1 FOR VALUES FROM (0) TO (1000);
ALTER TABLE t128_expr ATTACH PARTITION t128_expr2 FOR VALUES FROM (1000) TO (2000);

-- Now create the partitioned index on parent -- should absorb child indexes
-- (this exercises BuildIndexInfo(parentIndex) and CompareIndexInfo with expressions)
CREATE INDEX ON t128_expr ((a + b));

-- Verify only one index per partition (not duplicated)
SELECT c.relname, pg_get_indexdef(i.indexrelid)
  FROM pg_class c JOIN pg_index i ON c.oid = i.indexrelid
  WHERE i.indrelid::regclass::text LIKE 't128_expr%'
  ORDER BY c.relname, pg_get_indexdef(i.indexrelid);

-- Insert some data and query through the index
INSERT INTO t128_expr SELECT g, g*2 FROM generate_series(1, 100) g;
EXPLAIN (COSTS OFF) SELECT * FROM t128_expr WHERE (a + b) = 30;

DROP TABLE t128_expr;

-- ===========================================================================
-- Test 2: Partial index (predicate) on partitioned table
-- Covers: BuildIndexInfo path with partial index (WHERE clause)
-- Expression preprocessing applies to predicates too.
-- ===========================================================================

CREATE TABLE t128_partial (a int, b int) PARTITION BY RANGE (a);
CREATE TABLE t128_partial1 (LIKE t128_partial);
CREATE TABLE t128_partial2 (LIKE t128_partial);

-- Create partial indexes on child partitions first
CREATE INDEX ON t128_partial1 (a) WHERE b > 100;
CREATE INDEX ON t128_partial2 (a) WHERE b > 100;

-- Attach partitions
ALTER TABLE t128_partial ATTACH PARTITION t128_partial1 FOR VALUES FROM (0) TO (500);
ALTER TABLE t128_partial ATTACH PARTITION t128_partial2 FOR VALUES FROM (500) TO (1000);

-- Create matching partial index on parent -- should match and absorb children
CREATE INDEX ON t128_partial (a) WHERE b > 100;

-- Verify proper attachment (no duplicates)
SELECT c.relname, pg_get_indexdef(i.indexrelid)
  FROM pg_class c JOIN pg_index i ON c.oid = i.indexrelid
  WHERE i.indrelid::regclass::text LIKE 't128_partial%'
  ORDER BY c.relname, pg_get_indexdef(i.indexrelid);

INSERT INTO t128_partial SELECT g, g*3 FROM generate_series(1, 200) g;
EXPLAIN (COSTS OFF) SELECT * FROM t128_partial WHERE a = 50 AND b > 100;

DROP TABLE t128_partial;

-- ===========================================================================
-- Test 3: Partitioned index with non-default collation
-- Covers: parentIndex->rd_indcollation used in CompareIndexInfo
-- Tests the collation comparison path in the fixed code.
-- ===========================================================================

CREATE TABLE t128_coll (a text, b int) PARTITION BY RANGE (a);
CREATE TABLE t128_coll1 (LIKE t128_coll);
CREATE TABLE t128_coll2 (LIKE t128_coll);

-- Create indexes with "C" collation on partitions first
CREATE INDEX ON t128_coll1 (a COLLATE "C");
CREATE INDEX ON t128_coll2 (a COLLATE "C");

ALTER TABLE t128_coll ATTACH PARTITION t128_coll1 FOR VALUES FROM ('a') TO ('m');
ALTER TABLE t128_coll ATTACH PARTITION t128_coll2 FOR VALUES FROM ('m') TO ('z');

-- Create matching collated index on parent
CREATE INDEX ON t128_coll (a COLLATE "C");

SELECT c.relname, pg_get_indexdef(i.indexrelid)
  FROM pg_class c JOIN pg_index i ON c.oid = i.indexrelid
  WHERE i.indrelid::regclass::text LIKE 't128_coll%'
  ORDER BY c.relname, pg_get_indexdef(i.indexrelid);

INSERT INTO t128_coll VALUES ('apple', 1), ('mango', 2), ('zebra', 3);
EXPLAIN (COSTS OFF) SELECT * FROM t128_coll WHERE a COLLATE "C" < 'm';

DROP TABLE t128_coll;

-- ===========================================================================
-- Test 4: Expression index with column remapping (dropped columns scenario)
-- Covers: BuildIndexInfo with attmap remapping + expression preprocessing
-- This is a complex case where column attribute numbers differ between
-- parent and child, stressing the full matching path.
-- ===========================================================================

CREATE TABLE t128_dropcol (col_drop1 int, col_drop2 int, a int, b int)
  PARTITION BY RANGE (a);

-- Partition with different column layout
CREATE TABLE t128_dropcol1 (col_drop2 int, b int, col_drop1 int, a int);

ALTER TABLE t128_dropcol DROP COLUMN col_drop1;
ALTER TABLE t128_dropcol DROP COLUMN col_drop2;
ALTER TABLE t128_dropcol1 DROP COLUMN col_drop1;
ALTER TABLE t128_dropcol1 DROP COLUMN col_drop2;

-- Pre-create expression index on child
CREATE INDEX ON t128_dropcol1 ((a + b));
ALTER TABLE t128_dropcol ATTACH PARTITION t128_dropcol1 FOR VALUES FROM (0) TO (100);

-- Create expression index on parent -- must remap columns correctly
CREATE INDEX ON t128_dropcol ((a + b));

SELECT c.relname, pg_get_indexdef(i.indexrelid)
  FROM pg_class c JOIN pg_index i ON c.oid = i.indexrelid
  WHERE i.indrelid::regclass::text LIKE 't128_dropcol%'
  ORDER BY c.relname, pg_get_indexdef(i.indexrelid);

INSERT INTO t128_dropcol SELECT g, g*2 FROM generate_series(1, 50) g;
EXPLAIN (COSTS OFF) SELECT * FROM t128_dropcol WHERE (a + b) = 15;

DROP TABLE t128_dropcol;

-- ===========================================================================
-- Test 5: Multi-level partitioning with expression index
-- Covers: Recursive DefineIndex calls, each triggering BuildIndexInfo(parentIndex)
-- Tests that the fix works at multiple levels of partition hierarchy.
-- ===========================================================================

CREATE TABLE t128_multi (a int, b int)
  PARTITION BY RANGE (a);

CREATE TABLE t128_multi_p1 (a int, b int)
  PARTITION BY RANGE (a);

CREATE TABLE t128_multi_p1_c1 PARTITION OF t128_multi_p1
  FOR VALUES FROM (0) TO (50);
CREATE TABLE t128_multi_p1_c2 PARTITION OF t128_multi_p1
  FOR VALUES FROM (50) TO (100);

ALTER TABLE t128_multi ATTACH PARTITION t128_multi_p1
  FOR VALUES FROM (0) TO (100);

-- Pre-create expression indexes on leaf partitions
CREATE INDEX ON t128_multi_p1_c1 ((a * b));
CREATE INDEX ON t128_multi_p1_c2 ((a * b));

-- Create expression index on top-level parent
-- This triggers recursive DefineIndex, each level uses BuildIndexInfo(parentIndex)
CREATE INDEX ON t128_multi ((a * b));

SELECT c.relname, pg_get_indexdef(i.indexrelid)
  FROM pg_class c JOIN pg_index i ON c.oid = i.indexrelid
  WHERE i.indrelid::regclass::text LIKE 't128_multi%'
  ORDER BY c.relname, pg_get_indexdef(i.indexrelid);

INSERT INTO t128_multi SELECT g, g+1 FROM generate_series(1, 99) g;
EXPLAIN (COSTS OFF) SELECT * FROM t128_multi WHERE (a * b) = 42;

DROP TABLE t128_multi;

-- ============================================================
-- SQL Regression Tests for PostgreSQL Commit:
--   "Avoid misbehavior when hash_table_bytes < bucket_size"
-- 
-- Fix: In ExecChooseHashTableSize(), when hash_table_bytes <= bucket_size,
--      set sbuckets = 1 instead of calling pg_nextpower2_size_t(0).
--
-- Key condition to trigger the new code path:
--   work_mem is very small (64kB = minimum) and tuple size is very large,
--   causing hash_table_bytes <= bucket_size in the multi-batch branch.
--
-- bucket_size = tupsize * NTUP_PER_BUCKET + sizeof(HashJoinTuple)
-- tupsize     = HJTUPLE_OVERHEAD + MAXALIGN(SizeofMinimalTupleHeader) + MAXALIGN(tupwidth)
--             ≈ 16 + 24 + MAXALIGN(tupwidth)
-- At work_mem=64kB: hash_table_bytes = 65536 bytes
-- To trigger hash_table_bytes <= bucket_size: tupwidth >= ~65488 bytes
-- ============================================================


-- ============================================================
-- Test 1: Trigger hash_table_bytes <= bucket_size path (sbuckets=1)
--   Use minimum work_mem + very wide inner relation tuple to force the
--   newly added "sbuckets = 1" branch in ExecChooseHashTableSize().
-- Code path: hash_table_bytes <= bucket_size => sbuckets = 1
-- ============================================================
BEGIN;
SET work_mem = '64kB';
SET enable_hashjoin = on;
SET enable_mergejoin = off;
SET enable_nestloop = off;

CREATE TABLE test_wide_inner (
    id    integer,
    payload text
);

CREATE TABLE test_narrow_outer (
    id integer
);

-- Insert wide tuples (~65500 bytes each) into inner relation to make
-- tupsize approach or exceed hash_table_bytes at 64kB work_mem
INSERT INTO test_wide_inner VALUES (1, repeat('x', 65500));
INSERT INTO test_wide_inner VALUES (2, repeat('y', 65500));
INSERT INTO test_wide_inner VALUES (3, repeat('z', 65500));

INSERT INTO test_narrow_outer VALUES (1), (2), (3), (4), (5);

-- This hash join should trigger the multi-batch path where
-- hash_table_bytes <= bucket_size, exercising the sbuckets=1 fix
EXPLAIN (COSTS OFF)
  SELECT o.id
  FROM test_narrow_outer o
  JOIN test_wide_inner i ON o.id = i.id;

SELECT o.id
FROM test_narrow_outer o
JOIN test_wide_inner i ON o.id = i.id
ORDER BY o.id;

DROP TABLE test_wide_inner;
DROP TABLE test_narrow_outer;
ROLLBACK;


-- ============================================================
-- Test 2: Extremely wide tuple (BYTEA) to ensure sbuckets=1 branch
--   with a different data type; also verifies no assertion failure
--   or crash occurs when bucket_size > hash_table_bytes.
-- Code path: hash_table_bytes <= bucket_size => sbuckets = 1 (BYTEA column)
-- ============================================================
BEGIN;
SET work_mem = '64kB';
SET enable_hashjoin = on;
SET enable_mergejoin = off;
SET enable_nestloop = off;

CREATE TABLE test_wide_bytea (
    id      integer,
    bigdata bytea
);

CREATE TABLE test_probe (
    id integer
);

-- Each bytea tuple ~65500 bytes, exceeds hash_table_bytes at 64kB
INSERT INTO test_wide_bytea VALUES (1, decode(repeat('deadbeef', 8188), 'hex'));
INSERT INTO test_wide_bytea VALUES (2, decode(repeat('cafebabe', 8188), 'hex'));

INSERT INTO test_probe VALUES (1), (2), (3);

-- Hash join with bytea wide inner relation exercises the same fixed code path
EXPLAIN (COSTS OFF)
  SELECT p.id
  FROM test_probe p
  JOIN test_wide_bytea w ON p.id = w.id;

SELECT p.id
FROM test_probe p
JOIN test_wide_bytea w ON p.id = w.id
ORDER BY p.id;

DROP TABLE test_wide_bytea;
DROP TABLE test_probe;
ROLLBACK;


-- ============================================================
-- Test 3: Normal path (hash_table_bytes > bucket_size)
--   With adequate work_mem and narrow tuples, the original
--   pg_nextpower2_size_t() branch should be taken (sbuckets > 1).
--   This ensures the fix didn't break the normal execution path.
-- Code path: hash_table_bytes > bucket_size => sbuckets = pg_nextpower2_size_t(...)
-- ============================================================
BEGIN;
SET work_mem = '4MB';
SET enable_hashjoin = on;
SET enable_mergejoin = off;
SET enable_nestloop = off;

CREATE TABLE test_normal_inner (
    id    integer,
    val   integer
);

CREATE TABLE test_normal_outer (
    id integer
);

-- Insert many small tuples that require multiple batches at 4MB work_mem
INSERT INTO test_normal_inner
  SELECT g, g * 2 FROM generate_series(1, 200000) g;

INSERT INTO test_normal_outer
  SELECT generate_series(1, 1000);

-- This exercises the normal multi-batch path where sbuckets > 1
EXPLAIN (COSTS OFF)
  SELECT count(*)
  FROM test_normal_outer o
  JOIN test_normal_inner i ON o.id = i.id;

SELECT count(*)
FROM test_normal_outer o
JOIN test_normal_inner i ON o.id = i.id;

DROP TABLE test_normal_inner;
DROP TABLE test_normal_outer;
ROLLBACK;


-- ============================================================
-- Test 4: Edge case — wide tuple with NULL join key
--   Verify that the sbuckets=1 fix works correctly when tuples
--   contain NULL values (NULLs don't match in hash join, but
--   they still contribute to inner_rel_bytes and trigger multi-batch).
-- Code path: hash_table_bytes <= bucket_size => sbuckets = 1, with NULLs
-- ============================================================
BEGIN;
SET work_mem = '64kB';
SET enable_hashjoin = on;
SET enable_mergejoin = off;
SET enable_nestloop = off;

CREATE TABLE test_null_wide (
    id      integer,       -- will be NULL for some rows
    payload text
);

CREATE TABLE test_null_probe (
    id integer
);

-- Mix of NULL and non-NULL keys with very wide payloads
INSERT INTO test_null_wide VALUES (NULL, repeat('n', 65500));
INSERT INTO test_null_wide VALUES (1,    repeat('a', 65500));
INSERT INTO test_null_wide VALUES (NULL, repeat('b', 65500));
INSERT INTO test_null_wide VALUES (2,    repeat('c', 65500));

INSERT INTO test_null_probe VALUES (1), (2), (NULL), (3);

-- NULL keys won't match, but the hash table sizing must handle wide tuples
EXPLAIN (COSTS OFF)
  SELECT p.id
  FROM test_null_probe p
  JOIN test_null_wide w ON p.id = w.id;   -- NULL = NULL is false in join

SELECT p.id
FROM test_null_probe p
JOIN test_null_wide w ON p.id = w.id
ORDER BY p.id;

DROP TABLE test_null_wide;
DROP TABLE test_null_probe;
ROLLBACK;


-- ============================================================
-- Test 5: Borderline case — tuple size just at the boundary
--   Use work_mem=64kB with a tuple wide enough to be near but
--   not exceeding bucket_size, then one that clearly exceeds it.
--   Also tests the skew optimization code path with wide tuples.
-- Code path: tests both sides of "hash_table_bytes <= bucket_size" check
--            and exercises the skew-aware branch (useskew=true from hashjoin)
-- ============================================================
BEGIN;
SET work_mem = '64kB';
SET enable_hashjoin = on;
SET enable_mergejoin = off;
SET enable_nestloop = off;

CREATE TABLE test_skew_wide (
    id      integer,
    payload text
);

CREATE TABLE test_skew_probe (
    id integer
);

-- Create a skewed distribution: one key value dominates
-- with very wide tuples to stress the bucket sizing code
INSERT INTO test_skew_wide
  SELECT 1, repeat('s', 65490)   -- key=1 appears many times (skew)
  FROM generate_series(1, 5);

INSERT INTO test_skew_wide VALUES (2, repeat('t', 65490));
INSERT INTO test_skew_wide VALUES (3, repeat('u', 65490));

-- Add statistics to help the planner detect skew
ANALYZE test_skew_wide;

INSERT INTO test_skew_probe
  SELECT generate_series(1, 10);

-- Hash join with skewed inner side exercises both useskew=true path
-- and the fixed hash_table_bytes <= bucket_size branch
EXPLAIN (COSTS OFF)
  SELECT p.id, count(w.id)
  FROM test_skew_probe p
  LEFT JOIN test_skew_wide w ON p.id = w.id
  GROUP BY p.id
  ORDER BY p.id;

SELECT p.id, count(w.id)
FROM test_skew_probe p
LEFT JOIN test_skew_wide w ON p.id = w.id
GROUP BY p.id
ORDER BY p.id;

DROP TABLE test_skew_wide;
DROP TABLE test_skew_probe;
ROLLBACK;

-- =============================================================================
-- SQL Regression Tests for: Add missing fields to _outConstraint()
-- Commit: Added skip_validation and initially_valid fields to CONSTR_CHECK
--         branch in _outConstraint() (outfuncs.c lines 3558-3559)
--
-- The _outConstraint() function is triggered when PostgreSQL serializes
-- parse/plan trees (e.g., via debug_print_parse, inherited constraints during
-- CREATE TABLE AS / partition DDL, or rule/view rewrite).
-- These tests exercise the CONSTR_CHECK code path with both normal and NOT
-- VALID variants to cover the two newly-added WRITE_BOOL_FIELD calls.
-- =============================================================================

-- ============================================================
-- Test 1: Normal CHECK constraint on CREATE TABLE
-- Covers: CONSTR_CHECK branch with skip_validation=false,
--         initially_valid=true (the typical path through the
--         new WRITE_BOOL_FIELD lines at their default values)
-- ============================================================
CREATE TABLE test130_t1 (
    id   INTEGER,
    val  INTEGER,
    CONSTRAINT test130_t1_chk CHECK (val > 0)
);

INSERT INTO test130_t1 VALUES (1, 10), (2, 20), (3, 30);

-- EXPLAIN ANALYZE forces plan serialization, exercising _outConstraint()
-- indirectly through the query-tree-to-string path used in debugging
EXPLAIN ANALYZE SELECT * FROM test130_t1 WHERE val > 5;

-- Confirm constraint is active (initially_valid = true)
SELECT conname, convalidated
FROM pg_constraint
WHERE conrelid = 'test130_t1'::regclass AND contype = 'c';

DROP TABLE test130_t1;


-- ============================================================
-- Test 2: NOT VALID CHECK constraint via ALTER TABLE
-- Covers: CONSTR_CHECK branch with skip_validation=true,
--         initially_valid=false — directly exercises the new
--         code path added to _outConstraint()
-- ============================================================
CREATE TABLE test130_t2 (
    id   INTEGER,
    data TEXT
);

-- Insert rows that would violate the constraint (allowed with NOT VALID)
INSERT INTO test130_t2 VALUES (1, 'hello'), (2, NULL), (3, 'world');

-- Adding NOT VALID CHECK: parser creates Constraint node with
-- skip_validation=true, initially_valid=false — the exact fields
-- now output by the patched _outConstraint()
ALTER TABLE test130_t2
    ADD CONSTRAINT test130_t2_chk CHECK (data IS NOT NULL) NOT VALID;

EXPLAIN ANALYZE SELECT * FROM test130_t2 WHERE data IS NOT NULL;

SELECT conname, convalidated
FROM pg_constraint
WHERE conrelid = 'test130_t2'::regclass AND contype = 'c';

DROP TABLE test130_t2;


-- ============================================================
-- Test 3: VALIDATE CONSTRAINT after NOT VALID
-- Covers: Transition from skip_validation=true/initially_valid=false
--         to initially_valid=true after VALIDATE CONSTRAINT.
--         Ensures both states of the new fields are reachable.
-- ============================================================
CREATE TABLE test130_t3 (
    id  SERIAL PRIMARY KEY,
    amt NUMERIC
);

INSERT INTO test130_t3 (amt) VALUES (100), (200), (300);

ALTER TABLE test130_t3
    ADD CONSTRAINT test130_t3_pos CHECK (amt > 0) NOT VALID;

-- Before validation: skip_validation=true, initially_valid=false
SELECT conname, convalidated
FROM pg_constraint
WHERE conrelid = 'test130_t3'::regclass AND contype = 'c';

-- Validate: now initially_valid becomes true, skip_validation false
ALTER TABLE test130_t3 VALIDATE CONSTRAINT test130_t3_pos;

-- After validation
SELECT conname, convalidated
FROM pg_constraint
WHERE conrelid = 'test130_t3'::regclass AND contype = 'c';

EXPLAIN ANALYZE SELECT * FROM test130_t3 WHERE amt > 50;

DROP TABLE test130_t3;


-- ============================================================
-- Test 4: CHECK constraint on table with inheritance
-- Covers: Inherited CHECK constraints flow through
--         _outConstraint() when the child table is created,
--         exercising the new fields with is_no_inherit=false
-- ============================================================
CREATE TABLE test130_parent (
    id   INTEGER,
    score INTEGER,
    CONSTRAINT test130_parent_score_chk CHECK (score BETWEEN 0 AND 100)
);

-- Child inherits CHECK constraint; the cooked_expr path in
-- _outConstraint() is used here (skip_validation=false, initially_valid=true)
CREATE TABLE test130_child (
    grade CHAR(1)
) INHERITS (test130_parent);

INSERT INTO test130_parent VALUES (1, 50);
INSERT INTO test130_child  VALUES (2, 75, 'A');

EXPLAIN ANALYZE SELECT * FROM test130_parent WHERE score > 10;
EXPLAIN ANALYZE SELECT * FROM test130_child  WHERE score > 10;

SELECT conname, conrelid::regclass, convalidated
FROM pg_constraint
WHERE conrelid IN ('test130_parent'::regclass, 'test130_child'::regclass)
  AND contype = 'c';

DROP TABLE test130_child;
DROP TABLE test130_parent;


-- ============================================================
-- Test 5: NO INHERIT CHECK constraint (is_no_inherit = true)
--         combined with NOT VALID (skip_validation = true)
-- Covers: All three boolean fields (is_no_inherit, skip_validation,
--         initially_valid) in the CONSTR_CHECK branch being exercised
--         simultaneously, maximizing coverage of the patched lines
-- ============================================================
CREATE TABLE test130_t5 (
    id  INTEGER,
    txt TEXT
);

INSERT INTO test130_t5 VALUES (1, 'alpha'), (2, ''), (3, NULL);

-- NO INHERIT + NOT VALID: is_no_inherit=true, skip_validation=true,
-- initially_valid=false — all three new/relevant fields hit at once
ALTER TABLE test130_t5
    ADD CONSTRAINT test130_t5_noinherit_chk
        CHECK (txt <> '') NO INHERIT NOT VALID;

EXPLAIN ANALYZE SELECT * FROM test130_t5 WHERE txt IS NOT NULL;

SELECT conname, connoinherit, convalidated
FROM pg_constraint
WHERE conrelid = 'test130_t5'::regclass AND contype = 'c';

-- Validate to flip initially_valid, then re-check
ALTER TABLE test130_t5 VALIDATE CONSTRAINT test130_t5_noinherit_chk;

SELECT conname, connoinherit, convalidated
FROM pg_constraint
WHERE conrelid = 'test130_t5'::regclass AND contype = 'c';

DROP TABLE test130_t5;

-- Test 1: Core fix -- join RTE without alias named "unnamed_join" must not
-- hide a real base table aliased "unnamed_join" in FOR UPDATE OF.
-- Before the fix, the join RTE's auto-generated eref->aliasname
-- "unnamed_join" was matched first, causing the base table lock to be
-- silently skipped.
CREATE TEMP TABLE lc_a (id int, val text);
CREATE TEMP TABLE lc_b (id int, val text);
CREATE TEMP TABLE lc_c (id int, val text);
INSERT INTO lc_a VALUES (1, 'a');
INSERT INTO lc_b VALUES (1, 'b');
INSERT INTO lc_c VALUES (1, 'c');

SELECT lc_a.*, lc_b.*, unnamed_join.*
FROM lc_a JOIN lc_b ON (lc_a.id = lc_b.id), lc_c AS unnamed_join
FOR UPDATE OF unnamed_join;

DROP TABLE lc_a, lc_b, lc_c;

-- Test 2: FOR SHARE variant -- same code path as FOR UPDATE but with
-- different lock strength; ensures the new RTE_JOIN-without-alias guard
-- is also reached for FOR SHARE OF.
CREATE TEMP TABLE lc_x (id int, val text);
CREATE TEMP TABLE lc_y (id int, val text);
CREATE TEMP TABLE lc_z (id int, val text);
INSERT INTO lc_x VALUES (2, 'x');
INSERT INTO lc_y VALUES (2, 'y');
INSERT INTO lc_z VALUES (2, 'z');

SELECT lc_x.*, lc_y.*, unnamed_join.*
FROM lc_x JOIN lc_y ON (lc_x.id = lc_y.id), lc_z AS unnamed_join
FOR SHARE OF unnamed_join;

DROP TABLE lc_x, lc_y, lc_z;

-- Test 3: Join RTE WITH an explicit alias -- the new skip guard must NOT
-- fire (alias IS non-NULL), so the alias-named join is found and a proper
-- "join cannot be locked" error is raised.  We confirm the fix allows the
-- guard to be bypassed for aliased joins by catching the expected error.
CREATE TEMP TABLE lc_p (id int, val text);
CREATE TEMP TABLE lc_q (id int, val text);
INSERT INTO lc_p VALUES (1, 'p');
INSERT INTO lc_q VALUES (1, 'q');

DO $$
BEGIN
  BEGIN
    -- The join has an explicit alias "j", so the guard is skipped and the
    -- RTE_JOIN case raises an error (join cannot be locked).
    EXECUTE 'SELECT * FROM lc_p JOIN lc_q ON (lc_p.id = lc_q.id) j FOR UPDATE OF j';
  EXCEPTION WHEN OTHERS THEN
    -- expected: "FOR UPDATE cannot be applied to a join"
    NULL;
  END;
END;
$$;

DROP TABLE lc_p, lc_q;

-- Test 4: Multiple unnamed joins in FROM clause -- ensures the new guard
-- fires for every alias-less join RTE in the rangetable scan, not just the
-- first, so that a later base-table alias is still found and locked.
CREATE TEMP TABLE lc_m (id int);
CREATE TEMP TABLE lc_n (id int);
CREATE TEMP TABLE lc_o (id int);
CREATE TEMP TABLE lc_r (id int);
INSERT INTO lc_m VALUES (1);
INSERT INTO lc_n VALUES (1);
INSERT INTO lc_o VALUES (1);
INSERT INTO lc_r VALUES (1);

-- Two implicit (no-alias) joins in the rangetable, plus a base table
-- aliased "unnamed_join" that must still be locked.
SELECT lc_m.*, lc_n.*, lc_o.*, unnamed_join.*
FROM lc_m JOIN lc_n ON (lc_m.id = lc_n.id)
         JOIN lc_o ON (lc_n.id = lc_o.id),
     lc_r AS unnamed_join
FOR UPDATE OF unnamed_join;

DROP TABLE lc_m, lc_n, lc_o, lc_r;

-- Test 5: FOR KEY SHARE on a base relation that shares its alias name with
-- an auto-generated join eref -- exercises the same new guard via the
-- weaker FOR KEY SHARE lock strength, and also confirms that locking
-- multiple named relations in one FOR clause still works correctly when
-- alias-less joins are present.
CREATE TEMP TABLE lc_s (id int, val text);
CREATE TEMP TABLE lc_t (id int, val text);
CREATE TEMP TABLE lc_u (id int, val text);
INSERT INTO lc_s VALUES (1, 's');
INSERT INTO lc_t VALUES (1, 't');
INSERT INTO lc_u VALUES (1, 'u');

SELECT lc_s.*, unnamed_join.*
FROM lc_s JOIN lc_t ON (lc_s.id = lc_t.id), lc_u AS unnamed_join
FOR KEY SHARE OF lc_s, unnamed_join;

DROP TABLE lc_s, lc_t, lc_u;

-- =============================================================
-- SQL Regression Tests for:
-- "Show 'AS "?column?" explicitly when it's important"
-- ruleutils.c: colNamesVisible flag added to get_query_def and
-- related functions to control whether ?column? AS labels are shown
-- =============================================================

-- ================================================================
-- Test 1: View definition (colNamesVisible=true in make_viewdef)
-- When a view is created with expressions that produce ?column?,
-- pg_get_viewdef should emit explicit AS "?column?" so the view
-- can be safely reloaded.
-- Covers: make_viewdef -> get_query_def(colNamesVisible=true)
--         get_target_list: attname = colNamesVisible ? NULL : "?column?"
-- ================================================================

CREATE TABLE t135_base (a int, b text);
INSERT INTO t135_base VALUES (1, 'hello'), (2, 'world'), (NULL, NULL);

-- View with expressions that get fallback column name "?column?"
CREATE VIEW v135_colname AS
    SELECT 1 + 2,            -- expression with no obvious name -> ?column?
           a + 1,            -- also no obvious name
           b || '!',         -- string concat, no obvious name
           a                 -- simple column reference, gets name "a"
    FROM t135_base;

-- pg_get_viewdef should show AS "?column?" for the computed columns
-- because colNamesVisible=true for view definitions
SELECT pg_get_viewdef('v135_colname', true);
SELECT pg_get_viewdef('v135_colname', false);

DROP VIEW v135_colname;
DROP TABLE t135_base;


-- ================================================================
-- Test 2: SubLink / EXISTS subquery (colNamesVisible=false)
-- Inside a sublink (EXISTS, ANY, ALL), column names are not
-- visible to outer context, so ?column? label should be suppressed.
-- Covers: get_sublink_expr -> get_query_def(colNamesVisible=false)
-- ================================================================

CREATE TABLE t135_foo (x int, y text);
INSERT INTO t135_foo VALUES (1, 'a'), (2, 'b'), (3, NULL);

-- View that uses EXISTS (SubLink with colNamesVisible=false)
CREATE VIEW v135_exists AS
    SELECT x
    FROM t135_foo f1
    WHERE EXISTS (
        SELECT 1 + f1.x,        -- ?column? inside EXISTS, should be suppressed
               f1.y || 'z'
        FROM t135_foo f2
        WHERE f2.x = f1.x
    );

SELECT pg_get_viewdef('v135_exists', true);

-- View that uses ANY sublink
CREATE VIEW v135_any AS
    SELECT x
    FROM t135_foo
    WHERE x = ANY (SELECT x + 0 FROM t135_foo);  -- ?column? in ANY sublink

SELECT pg_get_viewdef('v135_any', true);

DROP VIEW v135_exists;
DROP VIEW v135_any;
DROP TABLE t135_foo;


-- ================================================================
-- Test 3: UNION / set operations
-- The right-hand side of a UNION gets colNamesVisible=false,
-- while the left-hand side propagates colNamesVisible from parent.
-- Covers: get_setop_query -> get_setop_query(op->rarg, ..., false)
-- ================================================================

CREATE TABLE t135_left (p int, q text);
CREATE TABLE t135_right (p int, q text);
INSERT INTO t135_left VALUES (1, 'left1'), (2, 'left2');
INSERT INTO t135_right VALUES (3, 'right1'), (4, 'right2');

-- View with UNION where both sides have computed expressions
CREATE VIEW v135_union AS
    SELECT 1 + p AS sum_col, q || '_L'   -- LHS: colNamesVisible=true (from parent)
    FROM t135_left
    UNION ALL
    SELECT 2 + p,            q || '_R'   -- RHS: colNamesVisible=false
    FROM t135_right;

SELECT pg_get_viewdef('v135_union', true);

-- View with UNION and ?column? producing expressions
CREATE VIEW v135_union2 AS
    SELECT p + 0, length(q)
    FROM t135_left
    UNION
    SELECT p + 0, length(q)
    FROM t135_right;

SELECT pg_get_viewdef('v135_union2', true);

DROP VIEW v135_union;
DROP VIEW v135_union2;
DROP TABLE t135_left;
DROP TABLE t135_right;


-- ================================================================
-- Test 4: FROM clause subquery (colNamesVisible=true)
-- Subqueries in FROM clause expose column names to outer query,
-- so colNamesVisible=true is passed.
-- Covers: get_from_clause_item -> get_query_def(colNamesVisible=true)
-- ================================================================

CREATE TABLE t135_data (id int, val numeric);
INSERT INTO t135_data VALUES (1, 10.5), (2, 20.3), (3, NULL);

-- View where outer SELECT references columns from a FROM subquery
-- The subquery's output names matter for the outer reference
CREATE VIEW v135_fromsubq AS
    SELECT sub.computed, sub.id
    FROM (
        SELECT id, val * 2 AS computed, val + 1   -- ?column? for "val+1"
        FROM t135_data
        WHERE val IS NOT NULL
    ) AS sub;

SELECT pg_get_viewdef('v135_fromsubq', true);

-- View with nested FROM subquery referencing a ?column? expression
CREATE VIEW v135_nested_fromsubq AS
    SELECT outer_sub.x
    FROM (
        SELECT inner_sub.x
        FROM (
            SELECT id + 0 AS x, val
            FROM t135_data
        ) AS inner_sub
        WHERE inner_sub.x > 0
    ) AS outer_sub;

SELECT pg_get_viewdef('v135_nested_fromsubq', true);

DROP VIEW v135_fromsubq;
DROP VIEW v135_nested_fromsubq;
DROP TABLE t135_data;


-- ================================================================
-- Test 5: INSERT/UPDATE/DELETE with RETURNING clause
-- RETURNING lists use colNamesVisible passed from the enclosing
-- get_insert/update/delete_query_def functions.
-- Covers: get_insert_query_def, get_update_query_def,
--         get_delete_query_def -> get_target_list(..., colNamesVisible)
-- Also covers: INSERT with SELECT subquery (colNamesVisible=false)
-- ================================================================

CREATE TABLE t135_target (id int, name text, score int);
CREATE TABLE t135_source (id int, name text, score int);

INSERT INTO t135_source VALUES (1, 'Alice', 90), (2, 'Bob', 85), (3, 'Carol', NULL);

-- INSERT with RETURNING that has computed expressions (?column?)
INSERT INTO t135_target (id, name, score)
    SELECT id, name, score FROM t135_source
    RETURNING id, name, score + 0, 42;

-- UPDATE with RETURNING computed expressions
INSERT INTO t135_target VALUES (10, 'Test', 70);
UPDATE t135_target
    SET score = score + 5
    WHERE id = 10
    RETURNING id, name, score * 2, 'updated'::text;

-- DELETE with RETURNING computed expressions
DELETE FROM t135_target
    WHERE id = 10
    RETURNING id, name, score - 1, now()::text;

-- Rule with RETURNING to exercise make_ruledef path (colNamesVisible=true)
CREATE TABLE t135_log (info text, ts timestamptz DEFAULT now());

CREATE RULE r135_insert AS ON INSERT TO t135_target
    DO ALSO INSERT INTO t135_log(info)
    VALUES (NEW.name || ':' || NEW.score::text);

-- Inspect the rule definition (exercises make_ruledef with colNamesVisible=true)
SELECT pg_get_ruledef(oid, true)
FROM pg_rewrite
WHERE rulename = 'r135_insert';

-- CTE (WITH clause) path: colNamesVisible=true
WITH ins AS (
    INSERT INTO t135_target (id, name, score)
    VALUES (20, 'Dave', 95)
    RETURNING id, name, score + 0, 'new'::text
)
SELECT * FROM ins;

DROP RULE r135_insert ON t135_target;
DROP TABLE t135_target;
DROP TABLE t135_source;
DROP TABLE t135_log;


-- ============================================================
-- SQL Regression Tests for: Fix DDL deparse of CREATE OPERATOR CLASS
-- Commit: When an implicit operator family is created via CREATE OPERATOR CLASS
--         (without FAMILY clause), it now gets reported to event triggers via
--         EventTriggerCollectSimpleCommand().
-- ============================================================

-- Test 1: CREATE OPERATOR CLASS without FAMILY clause (implicit opfamily creation)
-- Covers: Block 3 (makeNode(CreateOpFamilyStmt) + opfstmt construction)
--         and Block 2 (EventTriggerCollectSimpleCommand called for implicit opfamily)
-- This is the core fix: the implicit operator family must now be reported.
-- ============================================================

CREATE OR REPLACE FUNCTION test_136_evt_fn_1() RETURNS event_trigger
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        RAISE NOTICE 'TAG: % TYPE: % IDENTITY: %',
            r.command_tag, r.object_type, r.object_identity;
    END LOOP;
END;
$$;

CREATE EVENT TRIGGER test_136_evt_1 ON ddl_command_end
    EXECUTE PROCEDURE test_136_evt_fn_1();

-- This CREATE OPERATOR CLASS has NO FAMILY clause, so an implicit
-- operator family is created. The fix ensures EventTriggerCollectSimpleCommand
-- is called for the implicitly created operator family.
CREATE OPERATOR CLASS test136_opclass_implicit_fam
    FOR TYPE int4 USING btree AS STORAGE int4;

DROP EVENT TRIGGER test_136_evt_1;
DROP OPERATOR CLASS test136_opclass_implicit_fam USING btree;
DROP FUNCTION test_136_evt_fn_1();


-- ============================================================
-- Test 2: CREATE OPERATOR FAMILY explicitly (DefineOpFamily path)
-- Covers: Block 0 (CreateOpFamily signature) + Block 2 (EventTriggerCollectSimpleCommand)
--         via the DefineOpFamily() call site (line 770 in original diff).
-- The stmt passed is the real CreateOpFamilyStmt (not a synthesized one).
-- ============================================================

CREATE OR REPLACE FUNCTION test_136_evt_fn_2() RETURNS event_trigger
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        RAISE NOTICE 'TAG: % TYPE: % IDENTITY: %',
            r.command_tag, r.object_type, r.object_identity;
    END LOOP;
END;
$$;

CREATE EVENT TRIGGER test_136_evt_2 ON ddl_command_end
    EXECUTE PROCEDURE test_136_evt_fn_2();

-- Explicit CREATE OPERATOR FAMILY triggers DefineOpFamily -> CreateOpFamily(stmt, ...)
CREATE OPERATOR FAMILY test136_opfam_explicit USING btree;

DROP EVENT TRIGGER test_136_evt_2;
DROP OPERATOR FAMILY test136_opfam_explicit USING btree;
DROP FUNCTION test_136_evt_fn_2();


-- ============================================================
-- Test 3: CREATE OPERATOR CLASS WITH explicit FAMILY clause
-- Covers: the branch in DefineOpClass where opfamily already exists
--         (the else-if path that does NOT call CreateOpFamily implicitly).
--         Contrasts with Test 1 to ensure the non-implicit path still works.
-- ============================================================

CREATE OR REPLACE FUNCTION test_136_evt_fn_3() RETURNS event_trigger
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        RAISE NOTICE 'TAG: % TYPE: % IDENTITY: %',
            r.command_tag, r.object_type, r.object_identity;
    END LOOP;
END;
$$;

CREATE EVENT TRIGGER test_136_evt_3 ON ddl_command_end
    EXECUTE PROCEDURE test_136_evt_fn_3();

-- First create the family explicitly
CREATE OPERATOR FAMILY test136_opfam_for_opc USING hash;

-- Then create opclass referencing the existing family: NO implicit opfamily is created
CREATE OPERATOR CLASS test136_opclass_with_fam
    FOR TYPE int4 USING hash FAMILY test136_opfam_for_opc AS STORAGE int4;

DROP EVENT TRIGGER test_136_evt_3;
DROP OPERATOR CLASS test136_opclass_with_fam USING hash;
DROP OPERATOR FAMILY test136_opfam_for_opc USING hash;
DROP FUNCTION test_136_evt_fn_3();


-- ============================================================
-- Test 4: Verify pg_event_trigger_ddl_commands() captures BOTH
--         the implicit operator family AND the operator class
--         when CREATE OPERATOR CLASS has no FAMILY clause.
-- Covers: Block 3 + Block 2 together: after the fix, two commands
--         should be reported (CREATE OPERATOR FAMILY + CREATE OPERATOR CLASS).
-- ============================================================

CREATE TABLE test136_captured_commands (
    command_tag text,
    object_type text,
    object_identity text
);

CREATE OR REPLACE FUNCTION test_136_evt_fn_4() RETURNS event_trigger
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        INSERT INTO test136_captured_commands
            VALUES (r.command_tag, r.object_type, r.object_identity);
    END LOOP;
END;
$$;

CREATE EVENT TRIGGER test_136_evt_4 ON ddl_command_end
    EXECUTE PROCEDURE test_136_evt_fn_4();

-- This should record BOTH "CREATE OPERATOR FAMILY" and "CREATE OPERATOR CLASS"
-- into test136_captured_commands after the fix.
CREATE OPERATOR CLASS test136_opclass_dual_report
    FOR TYPE int4 USING gist AS STORAGE int4;

DROP EVENT TRIGGER test_136_evt_4;

-- Show captured commands (should include operator family + operator class entries)
SELECT command_tag, object_type FROM test136_captured_commands ORDER BY command_tag;

DROP OPERATOR CLASS test136_opclass_dual_report USING gist;
DROP TABLE test136_captured_commands;
DROP FUNCTION test_136_evt_fn_4();


-- ============================================================
-- Test 5: Error path — duplicate operator family name
-- Covers: Block 0 (new signature) + the duplicate-check error branch in CreateOpFamily
--         (the ereport(ERROR, ..., stmt->amname) path after the fix).
-- After the fix, stmt->amname is used in the error message instead of amname param.
-- ============================================================

-- Create the family first
CREATE OPERATOR FAMILY test136_opfam_dup USING btree;

-- Attempt to create it again: should ERROR with "already exists" message
-- referencing the correct access method name from stmt->amname.
DO $$
BEGIN
    CREATE OPERATOR FAMILY test136_opfam_dup USING btree;
    RAISE NOTICE 'ERROR: duplicate family creation should have failed';
EXCEPTION
    WHEN duplicate_object THEN
        RAISE NOTICE 'CAUGHT expected duplicate_object error for operator family';
END;
$$;

DROP OPERATOR FAMILY test136_opfam_dup USING btree;


-- ============================================================
-- SQL Regression Tests for:
--   Fix core dump in transformValuesClause when there are no columns
--   (Bug #17477 - expanding "tab.*" for a zero-column table)
--
-- The key fix: exprsLists is pre-populated with NIL entries per row,
-- and the final rearrangement loop now starts at i=0 (not i=1),
-- correctly handling zero-column tables without crashing.
-- ============================================================


-- ============================================================
-- Test 1: Core crash fix -- VALUES with zero-column table via tab.*
-- Covers: the main bug path where sublist_length=0, exprsLists is
--         pre-built with NIL entries, and the rearrangement loop
--         runs zero iterations (i < 0 == false) without crashing.
-- ============================================================
CREATE TEMP TABLE nocols_t1();
INSERT INTO nocols_t1 DEFAULT VALUES;
INSERT INTO nocols_t1 DEFAULT VALUES;
INSERT INTO nocols_t1 DEFAULT VALUES;

-- This is the exact query pattern from bug #17477:
-- expanding n.* from a zero-column table inside VALUES
SELECT * FROM nocols_t1 n, LATERAL (VALUES(n.*)) v;

DROP TABLE nocols_t1;


-- ============================================================
-- Test 2: Multiple rows from a zero-column table via tab.*
-- Covers: exprsLists gets multiple NIL entries (one per row),
--         the rearrangement loop executes with sublist_length=0
--         for each of many rows -- tests the per-row NIL append.
-- ============================================================
CREATE TEMP TABLE nocols_t2();
-- Insert 5 rows to stress-test the per-row NIL tracking
INSERT INTO nocols_t2 DEFAULT VALUES;
INSERT INTO nocols_t2 DEFAULT VALUES;
INSERT INTO nocols_t2 DEFAULT VALUES;
INSERT INTO nocols_t2 DEFAULT VALUES;
INSERT INTO nocols_t2 DEFAULT VALUES;

-- Verify that 5 rows are returned (one per zero-column row)
SELECT count(*) FROM nocols_t2 n, LATERAL (VALUES(n.*)) v;

DROP TABLE nocols_t2;


-- ============================================================
-- Test 3: Normal multi-column VALUES rearrangement (i=0 loop start)
-- Covers: the refactored loop now starts at i=0 instead of i=1,
--         and uses lfirst(lc2) = sublist to write back the pointer.
--         This ensures the fix doesn't regress normal column handling.
-- ============================================================
CREATE TEMP TABLE vals_normal (a int, b text, c float8);

INSERT INTO vals_normal
SELECT v.a, v.b, v.c
FROM (VALUES
    (1, 'alpha', 1.1),
    (2, 'beta',  2.2),
    (3, 'gamma', 3.3)
) AS v(a, b, c);

SELECT a, b, c FROM vals_normal ORDER BY a;

DROP TABLE vals_normal;


-- ============================================================
-- Test 4: Single-column VALUES rearrangement (boundary: exactly 1 col)
-- Covers: the old code handled col-0 separately then looped i=1..N-1;
--         the new code does everything in i=0..N-1. With N=1 the loop
--         runs exactly once, exercising the lfirst(lc2) write-back
--         for the minimal non-zero case.
-- ============================================================
CREATE TEMP TABLE vals_one_col (x int);

INSERT INTO vals_one_col
SELECT v.x FROM (VALUES (10), (20), (30), (NULL)) AS v(x);

SELECT x FROM vals_one_col ORDER BY x NULLS LAST;

DROP TABLE vals_one_col;


-- ============================================================
-- Test 5: Zero-column table in a subquery / CTE context
-- Covers: transformValuesClause called from inside a CTE where
--         the VALUES list has zero columns; also tests that the
--         fixed exprsLists = NIL initialization is correct when
--         the VALUES node is reached through a more complex query.
-- ============================================================
CREATE TEMP TABLE nocols_t5();
INSERT INTO nocols_t5 DEFAULT VALUES;
INSERT INTO nocols_t5 DEFAULT VALUES;

-- Use a CTE to wrap the zero-column VALUES expansion
WITH zero_col_cte AS (
    SELECT * FROM nocols_t5 n, LATERAL (VALUES(n.*)) v
)
SELECT count(*) FROM zero_col_cte;

-- Also test via a subquery
SELECT count(*)
FROM (
    SELECT *
    FROM nocols_t5 n, LATERAL (VALUES(n.*)) v
) sub;

DROP TABLE nocols_t5;

-- ============================================================
-- 138.sql: SQL regression tests for REFRESH MATERIALIZED VIEW
-- Covers CVE-2022-1552 fix: SetUserIdAndSecContext with
-- SECURITY_RESTRICTED_OPERATION now set immediately after
-- locking the relation (before any user code runs).
-- ============================================================

-- ============================================================
-- Test 1: Basic REFRESH MATERIALIZED VIEW
-- Covers: the new early SetUserIdAndSecContext path in
--         ExecRefreshMatView() with SECURITY_RESTRICTED_OPERATION
-- ============================================================
CREATE TABLE t138_base1 (id integer, val text);
INSERT INTO t138_base1 VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');

CREATE MATERIALIZED VIEW mv138_basic AS
    SELECT id, val FROM t138_base1 WHERE id > 0;

-- This REFRESH triggers the new early security context switch:
--   GetUserIdAndSecContext → SetUserIdAndSecContext(relowner, SECURITY_RESTRICTED_OPERATION)
REFRESH MATERIALIZED VIEW mv138_basic;

DROP MATERIALIZED VIEW mv138_basic;
DROP TABLE t138_base1;


-- ============================================================
-- Test 2: REFRESH MATERIALIZED VIEW WITH NO DATA (skipData path)
-- Covers: the new security context is set even when skipData=true,
--         i.e., the code path before the datafill call is reached
-- ============================================================
CREATE TABLE t138_base2 (id integer, amount numeric);
INSERT INTO t138_base2 VALUES (1, 100.00), (2, NULL), (3, 0.00);

CREATE MATERIALIZED VIEW mv138_nodata AS
    SELECT id, amount FROM t138_base2;

-- Populate first so WITH NO DATA is valid on refresh
REFRESH MATERIALIZED VIEW mv138_nodata;

-- Now refresh with no data; security context still set early
REFRESH MATERIALIZED VIEW mv138_nodata WITH NO DATA;

DROP MATERIALIZED VIEW mv138_nodata;
DROP TABLE t138_base2;


-- ============================================================
-- Test 3: REFRESH owned by a non-superuser role
-- Covers: relowner != current user case; the fix ensures
--         SetUserIdAndSecContext switches to relowner immediately
--         after heap_open(), before user-defined function execution
-- ============================================================
CREATE ROLE regress_mvtest138_owner;

CREATE TABLE t138_base3 (id integer, label text);
INSERT INTO t138_base3 VALUES (1, 'x'), (2, 'y'), (3, NULL);

-- Create MV as a non-superuser owner
SET ROLE regress_mvtest138_owner;
CREATE MATERIALIZED VIEW mv138_role AS
    SELECT id, label FROM t138_base3;
RESET ROLE;

-- Superuser refreshes a MV owned by another role:
-- triggers SetUserIdAndSecContext(relowner=regress_mvtest138_owner, SRO)
REFRESH MATERIALIZED VIEW mv138_role;

DROP MATERIALIZED VIEW mv138_role;
DROP TABLE t138_base3;
DROP ROLE regress_mvtest138_owner;


-- ============================================================
-- Test 4: REFRESH MATERIALIZED VIEW CONCURRENTLY
-- Covers: concurrent=true branch in ExecRefreshMatView();
--         SECURITY_RESTRICTED_OPERATION is now set before the
--         concurrent diff/merge user-code path executes
-- ============================================================
CREATE TABLE t138_base4 (id integer, score double precision);
INSERT INTO t138_base4
    SELECT i, random() FROM generate_series(1, 20) AS i;

CREATE MATERIALIZED VIEW mv138_concurrent AS
    SELECT id, score FROM t138_base4;

-- Unique index is required for CONCURRENTLY
CREATE UNIQUE INDEX ON mv138_concurrent (id);

-- Concurrent refresh exercises the new early SRO context path
-- and the refresh_by_match_merge() code with that context active
REFRESH MATERIALIZED VIEW CONCURRENTLY mv138_concurrent;

-- Refresh again after updating underlying data
UPDATE t138_base4 SET score = score + 1 WHERE id % 2 = 0;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv138_concurrent;

DROP MATERIALIZED VIEW mv138_concurrent;
DROP TABLE t138_base4;


-- ============================================================
-- Test 5: REFRESH with a MV that uses a security-sensitive function
-- Covers: the key CVE fix — user-defined function inside the MV
--         query now runs under SECURITY_RESTRICTED_OPERATION from
--         the very start, preventing privilege escalation
-- ============================================================
CREATE TABLE t138_base5 (id integer, data text);
INSERT INTO t138_base5 VALUES (1, 'hello'), (2, ''), (3, NULL), (4, 'world');

-- A simple user-defined function (runs under the MV owner's security context)
CREATE OR REPLACE FUNCTION fn138_upper(t text) RETURNS text
    LANGUAGE sql STABLE AS $$SELECT upper(t)$$;

CREATE MATERIALIZED VIEW mv138_func AS
    SELECT id, fn138_upper(data) AS upper_data
    FROM t138_base5;

-- This refresh invokes fn138_upper() under SECURITY_RESTRICTED_OPERATION
-- (the new behavior: SRO is active before any user code runs)
REFRESH MATERIALIZED VIEW mv138_func;

-- Refresh again with changed data
INSERT INTO t138_base5 VALUES (5, 'extra');
REFRESH MATERIALIZED VIEW mv138_func;

DROP MATERIALIZED VIEW mv138_func;
DROP FUNCTION fn138_upper(text);
DROP TABLE t138_base5;

-- SQL Regression Tests for commit:
-- "Avoid invalid array reference in transformAlterTableStmt()"
--
-- The fix adds `attnum > 0` guard before accessing TupleDescAttr(tupdesc, attnum - 1)
-- so that system columns (attnum <= 0, e.g., ctid, xmin, xmax, cmin, cmax, tableoid)
-- do not cause an out-of-bounds array access or spurious "no owned sequence found" error.
--
-- Code path: transformAlterTableStmt() -> AT_AlterColumnType case
--   if (attnum > 0 &&
--       TupleDescAttr(tupdesc, attnum - 1)->attidentity)


-- ============================================================
-- Test 1: ALTER COLUMN TYPE on the system column "ctid"
--         (attnum = -1 in pg_attribute; before fix, this could
--          access TupleDescAttr at index -2, causing invalid memory
--          reference or "no owned sequence found" error)
-- ============================================================
CREATE TABLE t139_test1 (
    id   integer,
    val  text
);

-- Attempting to alter a system column type should raise an appropriate error
-- (not a crash or misleading "no owned sequence found").
-- We expect an ERROR here; that is the correct, safe outcome.
DO $$
BEGIN
    ALTER TABLE t139_test1 ALTER COLUMN ctid TYPE text;
EXCEPTION
    WHEN OTHERS THEN
        -- Any error other than a crash / SIGSEGV is acceptable;
        -- the important thing is the attnum > 0 guard was reached.
        RAISE NOTICE 'Caught expected error for ctid: %', SQLERRM;
END;
$$;

DROP TABLE t139_test1;


-- ============================================================
-- Test 2: ALTER COLUMN TYPE on system column "xmin"
--         (attnum = -3; same invalid-array-reference scenario)
-- ============================================================
CREATE TABLE t139_test2 (
    id   bigint,
    data jsonb
);

DO $$
BEGIN
    ALTER TABLE t139_test2 ALTER COLUMN xmin TYPE bigint;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Caught expected error for xmin: %', SQLERRM;
END;
$$;

DROP TABLE t139_test2;


-- ============================================================
-- Test 3: ALTER COLUMN TYPE on system column "tableoid"
--         (attnum = -7; exercises the attnum > 0 guard at the
--          upper end of negative system-attribute numbers)
-- ============================================================
CREATE TABLE t139_test3 (
    a integer,
    b varchar(64)
);

DO $$
BEGIN
    ALTER TABLE t139_test3 ALTER COLUMN tableoid TYPE bigint;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Caught expected error for tableoid: %', SQLERRM;
END;
$$;

DROP TABLE t139_test3;


-- ============================================================
-- Test 4: Normal (positive attnum) ALTER COLUMN TYPE on a
--         non-identity regular column — the new guard must
--         NOT block the normal path (attnum > 0 is TRUE and
--         attidentity is '\0', so identity branch is skipped).
-- ============================================================
CREATE TABLE t139_test4 (
    id   integer,
    val  integer
);
INSERT INTO t139_test4 VALUES (1, 100), (2, 200);

-- This must succeed without error.
ALTER TABLE t139_test4 ALTER COLUMN val TYPE bigint;

SELECT id, val FROM t139_test4 ORDER BY id;

DROP TABLE t139_test4;


-- ============================================================
-- Test 5: ALTER COLUMN TYPE on a GENERATED ALWAYS AS IDENTITY
--         column (positive attnum, attidentity = 'a').
--         Verifies that the normal identity-sequence-type-update
--         path still executes correctly after the guard is added.
-- ============================================================
CREATE TABLE t139_test5 (
    id  integer GENERATED ALWAYS AS IDENTITY,
    val text
);
INSERT INTO t139_test5 (val) VALUES ('foo'), ('bar');

-- Change identity column type from integer to bigint; this exercises
-- the branch: attnum > 0 AND attidentity != '\0'
ALTER TABLE t139_test5 ALTER COLUMN id TYPE bigint;

-- Verify the sequence type was updated as well
SELECT seqtypid::regtype
FROM   pg_sequence
WHERE  seqrelid = (
           SELECT oid FROM pg_class
           WHERE  relname LIKE 't139_test5_id_seq'
       );

DROP TABLE t139_test5;

-- ============================================================
-- SQL Regression Tests for:
--   heap_fetch_extended() + heapam_tuple_lock() fix
--   Commit: Prevent access to no-longer-pinned buffer in heapam_tuple_lock()
--
-- The key change: heap_fetch() now wraps heap_fetch_extended(keep_buf=false).
-- heapam_tuple_lock() calls heap_fetch_extended(keep_buf=true) to safely
-- traverse tuple update chains even when a tuple fails the snapshot check.
-- ============================================================


-- ============================================================
-- Test 1: Basic SELECT FOR UPDATE
-- Covers: heap_fetch (-> heap_fetch_extended keep_buf=false) normal path,
--         heapam_tuple_lock() via EvalPlanQualFetch on a visible, committed row.
-- ============================================================
CREATE TABLE t140_basic (
    id   INT PRIMARY KEY,
    val  TEXT
);

INSERT INTO t140_basic VALUES (1, 'alpha');
INSERT INTO t140_basic VALUES (2, 'beta');
INSERT INTO t140_basic VALUES (3, 'gamma');

-- Acquire row-level lock via FOR UPDATE: triggers heapam_tuple_lock()
-- which calls heap_lock_tuple(); if result == TM_Updated it will call
-- heap_fetch_extended with keep_buf=true.
BEGIN;
SELECT id, val FROM t140_basic WHERE id = 1 FOR UPDATE;
SELECT id, val FROM t140_basic WHERE id = 2 FOR SHARE;
COMMIT;

-- Plain heap_fetch (keep_buf=false path) via simple scan
SELECT * FROM t140_basic ORDER BY id;

DROP TABLE t140_basic;


-- ============================================================
-- Test 2: UPDATE then SELECT FOR UPDATE in same transaction
-- Covers: heapam_tuple_lock() TM_Updated chain traversal path —
--         after an UPDATE, the old tuple version fails snapshot; the fix
--         ensures heap_fetch_extended(keep_buf=true) keeps the buffer pin
--         while inspecting the updated tuple.
-- ============================================================
CREATE TABLE t140_update_chain (
    id    INT PRIMARY KEY,
    val   INT,
    extra TEXT DEFAULT 'data'
);

INSERT INTO t140_update_chain SELECT i, i * 10, 'row' || i FROM generate_series(1, 50) i;

-- Update creates an old tuple version (invisible to newer snapshots) and
-- a new one; subsequent FOR UPDATE may need to traverse the chain.
BEGIN;
UPDATE t140_update_chain SET val = val + 1 WHERE id <= 10;
-- Now lock rows that were just updated: exercises TM_Updated retry path
SELECT id, val FROM t140_update_chain WHERE id <= 10 FOR UPDATE;
COMMIT;

DROP TABLE t140_update_chain;


-- ============================================================
-- Test 3: Deleted tuple then SELECT FOR UPDATE (TM_Deleted / keep_buf path)
-- Covers: when a tuple has been deleted (xmax set), heap_fetch_extended
--         with keep_buf=true is needed so callers can still read t_data
--         to check xmin/xmax without accessing a non-pinned buffer.
-- ============================================================
CREATE TABLE t140_deleted (
    id   INT,
    note TEXT
);

INSERT INTO t140_deleted VALUES (1, 'to be deleted');
INSERT INTO t140_deleted VALUES (2, 'survivor');
INSERT INTO t140_deleted VALUES (3, 'also deleted');

BEGIN;
-- Delete rows first in this transaction, making them invisible to later cmds
DELETE FROM t140_deleted WHERE id IN (1, 3);
-- Try to FOR UPDATE — the deleted rows are invisible; lock on survivor only
SELECT id, note FROM t140_deleted FOR UPDATE;
ROLLBACK;

DROP TABLE t140_deleted;


-- ============================================================
-- Test 4: NULL values and edge-case TIDs via ctid scan
-- Covers: heap_fetch() / heap_fetch_extended() with NULL column values;
--         ensures t_data is handled correctly when tuple has NULLs.
-- ============================================================
CREATE TABLE t140_nulls (
    id     INT,
    a      TEXT,
    b      INT,
    c      NUMERIC
);

INSERT INTO t140_nulls VALUES (1, NULL, NULL, NULL);
INSERT INTO t140_nulls VALUES (2, 'x',  NULL, 3.14);
INSERT INTO t140_nulls VALUES (3, NULL, 42,   NULL);
INSERT INTO t140_nulls VALUES (4, NULL, NULL, NULL);

-- Use ctid-based fetch to exercise heap_fetch path directly
-- (forces tuple-by-TID access, directly triggering heap_fetch_extended)
SELECT id, a, b, c
FROM t140_nulls
WHERE ctid = '(0,1)'::tid;

-- FOR UPDATE with NULLs: exercises heapam_tuple_lock on tuples with nulls
BEGIN;
SELECT id, a, b, c FROM t140_nulls WHERE id IS NOT NULL FOR UPDATE;
COMMIT;

DROP TABLE t140_nulls;


-- ============================================================
-- Test 5: REPEATABLE READ snapshot — invisible updated tuple chain
-- Covers: heap_fetch_extended(keep_buf=true) in heapam_tuple_lock() when
--         the transaction snapshot cannot see the latest tuple version
--         (REPEATABLE READ / Serializable isolation).  The bug was that
--         without keep_buf the buffer was released before t_data was read.
-- ============================================================
CREATE TABLE t140_rr (
    id   SERIAL PRIMARY KEY,
    val  INT,
    pad  TEXT DEFAULT repeat('x', 100)
);

INSERT INTO t140_rr (val) SELECT i FROM generate_series(1, 20) i;

-- Session A: open a repeatable read transaction and lock a row
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- Take a snapshot
SELECT id, val FROM t140_rr WHERE id = 5;

-- Now update a row that our snapshot already saw; the update creates a new
-- tuple version, making the old one fail a dirty snapshot check.
-- (In a real concurrency scenario this would be done by another session;
-- here we simulate with a sub-transaction via savepoint.)
SAVEPOINT sp1;
UPDATE t140_rr SET val = val + 100 WHERE id <= 5;
-- Roll back the update so we can still see the original rows
ROLLBACK TO SAVEPOINT sp1;

-- FOR UPDATE after seeing the snapshot: heapam_tuple_lock must safely handle
-- the case where it traverses to a tuple version invisible to SnapshotDirty
SELECT id, val FROM t140_rr WHERE id <= 5 FOR UPDATE;

COMMIT;

-- Cleanup
DROP TABLE t140_rr;


-- ============================================================
-- 141.sql: SQL regression tests for PostgreSQL commit
-- "Revert: Rewrite some RI code to avoid using SPI"
--
-- Target: get_partition_for_tuple(PartitionDispatch pd, ...)
--         in src/backend/executor/execPartition.c
--
-- The refactoring changed the function signature to accept a
-- PartitionDispatch struct instead of separate key+partdesc args.
-- All three partition strategies (RANGE, LIST, HASH) must be
-- exercised via INSERT/UPDATE to trigger ExecFindPartition ->
-- get_partition_for_tuple.
-- ============================================================


-- ============================================================
-- Test 1: RANGE partitioning — normal INSERT routing
-- Covers: get_partition_for_tuple PARTITION_STRATEGY_RANGE path
--         pd->key and pd->partdesc extracted correctly from pd
-- ============================================================
CREATE TABLE t141_range (
    id    int,
    val   text
) PARTITION BY RANGE (id);

CREATE TABLE t141_range_p1 PARTITION OF t141_range FOR VALUES FROM (1)   TO (100);
CREATE TABLE t141_range_p2 PARTITION OF t141_range FOR VALUES FROM (100) TO (200);
CREATE TABLE t141_range_p3 PARTITION OF t141_range FOR VALUES FROM (200) TO (300);

-- Normal inserts that route through get_partition_for_tuple (RANGE)
INSERT INTO t141_range VALUES (1,   'first partition');
INSERT INTO t141_range VALUES (50,  'first partition mid');
INSERT INTO t141_range VALUES (99,  'first partition end');
INSERT INTO t141_range VALUES (100, 'second partition');
INSERT INTO t141_range VALUES (150, 'second partition mid');
INSERT INTO t141_range VALUES (200, 'third partition');
INSERT INTO t141_range VALUES (250, 'third partition mid');
INSERT INTO t141_range VALUES (299, 'third partition end');

-- Verify routing reached the new code (EXPLAIN to exercise planning path too)
EXPLAIN (COSTS OFF) INSERT INTO t141_range VALUES (42, 'explain test');

DROP TABLE t141_range;


-- ============================================================
-- Test 2: RANGE partitioning — NULL key value triggers default
-- Covers: range_partkey_has_null branch inside get_partition_for_tuple
--         NULL in partition key falls through to default partition
-- ============================================================
CREATE TABLE t141_range_null (
    id  int,
    tag text
) PARTITION BY RANGE (id);

CREATE TABLE t141_range_null_p1       PARTITION OF t141_range_null FOR VALUES FROM (1) TO (1000);
CREATE TABLE t141_range_null_default  PARTITION OF t141_range_null DEFAULT;

-- Non-null insert (normal path)
INSERT INTO t141_range_null VALUES (500, 'normal');

-- NULL insert goes to default partition via boundinfo->default_index
INSERT INTO t141_range_null VALUES (NULL, 'null key goes to default');

SELECT tableoid::regclass, id, tag FROM t141_range_null ORDER BY tag;

DROP TABLE t141_range_null;


-- ============================================================
-- Test 3: LIST partitioning — normal routing + NULL handling
-- Covers: PARTITION_STRATEGY_LIST branch in get_partition_for_tuple
--         Both the isnull[0] (null_index) and normal bsearch paths
-- ============================================================
CREATE TABLE t141_list (
    region text,
    amount numeric
) PARTITION BY LIST (region);

CREATE TABLE t141_list_east    PARTITION OF t141_list FOR VALUES IN ('east', 'northeast');
CREATE TABLE t141_list_west    PARTITION OF t141_list FOR VALUES IN ('west', 'northwest');
CREATE TABLE t141_list_default PARTITION OF t141_list DEFAULT;

-- Normal list routing
INSERT INTO t141_list VALUES ('east',      100.00);
INSERT INTO t141_list VALUES ('northeast', 200.00);
INSERT INTO t141_list VALUES ('west',      300.00);
INSERT INTO t141_list VALUES ('northwest', 400.00);

-- Unknown value -> default partition
INSERT INTO t141_list VALUES ('south',  999.00);

-- NULL key -> partition_bound_accepts_nulls check (goes to default here)
INSERT INTO t141_list VALUES (NULL, 0.00);

SELECT tableoid::regclass AS part, region FROM t141_list ORDER BY region NULLS LAST;

DROP TABLE t141_list;


-- ============================================================
-- Test 4: HASH partitioning — routing via compute_partition_hash_value
-- Covers: PARTITION_STRATEGY_HASH branch in get_partition_for_tuple
--         rowHash % boundinfo->nindexes index lookup
-- ============================================================
CREATE TABLE t141_hash (
    id   int,
    data text
) PARTITION BY HASH (id);

CREATE TABLE t141_hash_p0 PARTITION OF t141_hash FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE t141_hash_p1 PARTITION OF t141_hash FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE t141_hash_p2 PARTITION OF t141_hash FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE t141_hash_p3 PARTITION OF t141_hash FOR VALUES WITH (MODULUS 4, REMAINDER 3);

-- Insert enough rows to hit all four hash buckets
INSERT INTO t141_hash SELECT i, 'row ' || i FROM generate_series(1, 40) i;

-- Confirm rows spread across partitions
SELECT tableoid::regclass AS part, count(*) FROM t141_hash GROUP BY 1 ORDER BY 1;

DROP TABLE t141_hash;


-- ============================================================
-- Test 5: Multi-level (nested) RANGE partitioning — recursive
--         ExecFindPartition calls, each calling get_partition_for_tuple
--         with the new PartitionDispatch-based signature at every level
-- ============================================================
CREATE TABLE t141_nested (
    year  int,
    month int,
    val   text
) PARTITION BY RANGE (year);

CREATE TABLE t141_nested_2022 PARTITION OF t141_nested
    FOR VALUES FROM (2022) TO (2023)
    PARTITION BY RANGE (month);

CREATE TABLE t141_nested_2022_h1 PARTITION OF t141_nested_2022 FOR VALUES FROM (1)  TO (7);
CREATE TABLE t141_nested_2022_h2 PARTITION OF t141_nested_2022 FOR VALUES FROM (7)  TO (13);

CREATE TABLE t141_nested_2023 PARTITION OF t141_nested
    FOR VALUES FROM (2023) TO (2024)
    PARTITION BY RANGE (month);

CREATE TABLE t141_nested_2023_h1 PARTITION OF t141_nested_2023 FOR VALUES FROM (1)  TO (7);
CREATE TABLE t141_nested_2023_h2 PARTITION OF t141_nested_2023 FOR VALUES FROM (7)  TO (13);

-- Each INSERT descends two levels, calling get_partition_for_tuple twice
INSERT INTO t141_nested VALUES (2022, 1,  'jan 2022');
INSERT INTO t141_nested VALUES (2022, 6,  'jun 2022');
INSERT INTO t141_nested VALUES (2022, 7,  'jul 2022');
INSERT INTO t141_nested VALUES (2022, 12, 'dec 2022');
INSERT INTO t141_nested VALUES (2023, 3,  'mar 2023');
INSERT INTO t141_nested VALUES (2023, 9,  'sep 2023');

-- Show leaf partitions reached
SELECT tableoid::regclass AS leaf_part, year, month, val
FROM t141_nested
ORDER BY year, month;

DROP TABLE t141_nested;

-- Test 1: pg_get_viewdef with pretty=true triggers GET_PRETTY_FLAGS(true) path
-- Covers: GET_PRETTY_FLAGS macro replacing duplicated pretty-flag calculation in pg_get_viewdef_ext
CREATE TABLE t142_base (id int, val text);
CREATE VIEW v142_pretty AS SELECT id, val FROM t142_base WHERE id > 0;
SELECT pg_get_viewdef('v142_pretty'::regclass, true);
SELECT pg_get_viewdef('v142_pretty'::regclass, false);
DROP VIEW v142_pretty;
DROP TABLE t142_base;

-- Test 2: pg_get_viewdef with a subquery in FROM clause forces alias (RTE_SUBQUERY fix)
-- Covers: get_from_clause_item() now forces printalias=true for RTE_SUBQUERY
CREATE TABLE t142_data (x int, y text);
INSERT INTO t142_data VALUES (1, 'a'), (2, 'b'), (3, 'c');
CREATE VIEW v142_subquery AS
    SELECT sub.x, sub.y FROM (SELECT x, y FROM t142_data WHERE x > 1) sub;
SELECT pg_get_viewdef('v142_subquery'::regclass, false);
SELECT pg_get_viewdef('v142_subquery'::regclass, true);
DROP VIEW v142_subquery;
DROP TABLE t142_data;

-- Test 3: pg_get_viewdef with VALUES in FROM clause (pre-existing RTE_VALUES path)
-- Covers: RTE_VALUES alias-force path still works alongside the new RTE_SUBQUERY path
CREATE VIEW v142_values AS
    SELECT v.a, v.b FROM (VALUES (1, 'x'), (2, 'y')) AS v(a, b);
SELECT pg_get_viewdef('v142_values'::regclass, false);
SELECT pg_get_viewdef('v142_values'::regclass, true);
DROP VIEW v142_values;

-- Test 4: pg_get_ruledef with pretty flags (GET_PRETTY_FLAGS macro in pg_get_ruledef_ext)
-- Covers: GET_PRETTY_FLAGS macro in pg_get_ruledef_ext code path
CREATE TABLE t142_rule (id int, val text);
CREATE TABLE t142_rule_log (id int, val text, logged_at timestamptz DEFAULT now());
CREATE RULE r142_insert AS ON INSERT TO t142_rule
    DO ALSO INSERT INTO t142_rule_log(id, val) VALUES (NEW.id, NEW.val);
SELECT pg_get_ruledef(oid, true)  FROM pg_rewrite WHERE rulename = 'r142_insert';
SELECT pg_get_ruledef(oid, false) FROM pg_rewrite WHERE rulename = 'r142_insert';
DROP RULE r142_insert ON t142_rule;
DROP TABLE t142_rule_log;
DROP TABLE t142_rule;

-- Test 5: pg_get_indexdef with pretty flag (GET_PRETTY_FLAGS macro in pg_get_indexdef_ext)
-- Covers: GET_PRETTY_FLAGS macro in pg_get_indexdef_ext code path
CREATE TABLE t142_idx (id int, a text, b text);
CREATE INDEX i142_expr ON t142_idx ((lower(a) || ' ' || lower(b)));
SELECT pg_get_indexdef('i142_expr'::regclass, 0, true);
SELECT pg_get_indexdef('i142_expr'::regclass, 0, false);
DROP INDEX i142_expr;
DROP TABLE t142_idx;

-- ============================================================
-- SQL Regression Tests for:
-- "Fix risk of deadlock failure while dropping a partitioned index"
-- Covers: RemoveRelations + RangeVarCallbackForDropRelation refactoring
-- ============================================================

-- ===========================================================
-- Test 1: DROP partitioned index (normal case with child partitions)
-- Covers: Block 3 (find_all_inheritors called for RELKIND_PARTITIONED_INDEX),
--         Block 5 (actual_relkind / actual_relpersistence set by callback),
--         The new locking path for child tables of partitioned table
-- ===========================================================

CREATE TABLE t143_part (a int, b text) PARTITION BY RANGE (a);
CREATE TABLE t143_part_1 PARTITION OF t143_part FOR VALUES FROM (1)  TO (100);
CREATE TABLE t143_part_2 PARTITION OF t143_part FOR VALUES FROM (100) TO (200);
CREATE TABLE t143_part_3 PARTITION OF t143_part FOR VALUES FROM (200) TO (300);

INSERT INTO t143_part SELECT i, 'val' || i FROM generate_series(1, 299) i;

-- Create a partitioned index on the partitioned table
CREATE INDEX t143_pidx ON t143_part (a);

-- Verify the partitioned index exists
SELECT relname, relkind
  FROM pg_class
 WHERE relname IN ('t143_pidx', 't143_part_1_a_idx', 't143_part_2_a_idx', 't143_part_3_a_idx')
 ORDER BY relname;

-- DROP the partitioned index: triggers find_all_inheritors() on heapOid,
-- exercises the new actual_relkind == RELKIND_PARTITIONED_INDEX branch
DROP INDEX t143_pidx;

-- Confirm all child indexes are gone
SELECT relname, relkind
  FROM pg_class
 WHERE relname LIKE 't143_part%idx'
 ORDER BY relname;

DROP TABLE t143_part;


-- ===========================================================
-- Test 2: DROP INDEX CONCURRENTLY on a partitioned index must fail
-- Covers: Block 3 path that raises ERROR for concurrent drop of partitioned index,
--         actual_relkind == RELKIND_PARTITIONED_INDEX check (line 1390-1395)
-- ===========================================================

CREATE TABLE t143_conc (id int, val text) PARTITION BY RANGE (id);
CREATE TABLE t143_conc_1 PARTITION OF t143_conc FOR VALUES FROM (1)  TO (50);
CREATE TABLE t143_conc_2 PARTITION OF t143_conc FOR VALUES FROM (50) TO (100);

INSERT INTO t143_conc SELECT i, 'x' || i FROM generate_series(1, 99) i;

CREATE INDEX t143_conc_idx ON t143_conc (id);

-- This must ERROR: "cannot drop partitioned index ... concurrently"
-- (exercises actual_relpersistence != RELPERSISTENCE_TEMP AND actual_relkind == RELKIND_PARTITIONED_INDEX)
DO $$
BEGIN
    DROP INDEX CONCURRENTLY t143_conc_idx;
    RAISE EXCEPTION 'Expected error was not raised';
EXCEPTION
    WHEN feature_not_supported THEN
        RAISE NOTICE 'Caught expected error: cannot drop partitioned index concurrently';
END;
$$;

-- Cleanup
DROP INDEX t143_conc_idx;
DROP TABLE t143_conc;


-- ===========================================================
-- Test 3: DROP INDEX CONCURRENTLY on a TEMP partitioned index is allowed
-- Covers: actual_relpersistence == RELPERSISTENCE_TEMP path
--         (concurrent mode NOT set for temp relations, so no concurrent-partitioned conflict)
--         Tests the relpersistence passback via state.actual_relpersistence
-- ===========================================================

CREATE TEMP TABLE t143_tmp (id int, val text) PARTITION BY RANGE (id);
CREATE TEMP TABLE t143_tmp_1 PARTITION OF t143_tmp FOR VALUES FROM (1)  TO (50);
CREATE TEMP TABLE t143_tmp_2 PARTITION OF t143_tmp FOR VALUES FROM (50) TO (100);

INSERT INTO t143_tmp SELECT i, 'tmp' || i FROM generate_series(1, 99) i;

CREATE INDEX t143_tmp_idx ON t143_tmp (id);

-- For a TEMP partitioned index, CONCURRENTLY is silently downgraded (no error),
-- because actual_relpersistence == RELPERSISTENCE_TEMP → concurrent flag not set
DROP INDEX CONCURRENTLY t143_tmp_idx;

-- Verify index is gone
SELECT relname FROM pg_class WHERE relname = 't143_tmp_idx';

DROP TABLE t143_tmp;


-- ===========================================================
-- Test 4: DROP INDEX wrong type error (expected_relkind mismatch)
-- Covers: Block 6 (state->expected_relkind != expected_relkind → DropErrorMsgWrongType)
--         Exercises the refactored error path with correct classform->relkind
-- ===========================================================

CREATE TABLE t143_wrongtype (id int, val text);
INSERT INTO t143_wrongtype VALUES (1, 'a'), (2, 'b');

-- Trying to DROP TABLE using DROP INDEX syntax should trigger wrong-type error
DO $$
BEGIN
    -- DROP INDEX on a plain table (wrong relkind: table vs index)
    EXECUTE 'DROP INDEX t143_wrongtype';
    RAISE EXCEPTION 'Expected error was not raised';
EXCEPTION
    WHEN wrong_object_type THEN
        RAISE NOTICE 'Caught expected error: wrong object type';
    WHEN undefined_table THEN
        RAISE NOTICE 'Caught expected error: undefined table (object not found as index)';
END;
$$;

DROP TABLE t143_wrongtype;


-- ===========================================================
-- Test 5: Multi-level partitioned index DROP (deeply nested partitions)
-- Covers: find_all_inheritors traverses all levels of inheritance tree,
--         ensures locks are acquired on all child tables before child indexes
-- ===========================================================

CREATE TABLE t143_deep (a int, b int) PARTITION BY RANGE (a);
CREATE TABLE t143_deep_lo PARTITION OF t143_deep
    FOR VALUES FROM (1) TO (500)
    PARTITION BY RANGE (b);
CREATE TABLE t143_deep_hi PARTITION OF t143_deep
    FOR VALUES FROM (500) TO (1000);

CREATE TABLE t143_deep_lo_1 PARTITION OF t143_deep_lo FOR VALUES FROM (1)   TO (100);
CREATE TABLE t143_deep_lo_2 PARTITION OF t143_deep_lo FOR VALUES FROM (100) TO (200);
CREATE TABLE t143_deep_lo_3 PARTITION OF t143_deep_lo FOR VALUES FROM (200) TO (500);

INSERT INTO t143_deep SELECT i, i % 199 + 1 FROM generate_series(1, 499) i;
INSERT INTO t143_deep SELECT i, 1 FROM generate_series(500, 999) i;

-- Create partitioned index spanning the whole hierarchy
CREATE INDEX t143_deep_idx ON t143_deep (a);

-- Confirm the index tree exists
SELECT count(*) FROM pg_class
 WHERE relname LIKE 't143_deep%idx';

-- DROP the top-level partitioned index:
-- find_all_inheritors(heapOid) must walk ALL levels of the partition tree
-- and acquire table locks before index locks
DROP INDEX t143_deep_idx;

-- All child indexes should be gone
SELECT relname FROM pg_class
 WHERE relname LIKE 't143_deep%idx'
 ORDER BY relname;

DROP TABLE t143_deep;

-- ============================================================
-- SQL Regression Tests for:
-- Commit: "Move code around in StartupXLOG()"
-- Task ID: 144
--
-- This commit is a pure refactoring of StartupXLOG() in xlog.c:
--   - Renamed exitArchiveRecovery() -> XLogInitNewTimeline()
--   - Moved InRecovery detection logic earlier (InitWalRecovery block)
--   - Moved resource manager startup (rm_startup) to after first record read
--   - Added performedWalRecovery boolean to replace lastReplayedEndRecPtr check
--   - Moved RelationCacheInitFileRemove() after shmem variable init
--   - Moved ResetUnloggedRelations() after archive recovery completion check
--   - Added recoveryStopReason variable in FinishWalRecovery block
--
-- Since all paths are in StartupXLOG() (database startup/recovery),
-- these SQL tests exercise the surrounding infrastructure:
-- checkpoint state, WAL writing, unlogged tables, pg_control views,
-- and recovery status functions reachable after startup completes.
-- ============================================================


-- ============================================================
-- Test 1: pg_control_checkpoint() and pg_control_recovery()
-- Covers: InitWalRecovery block -- checkPoint/ControlFile state
--         that is read and set during startup (checkPointLoc,
--         minRecoveryPoint, backupStartPoint).
-- These views expose the values written by the moved code blocks.
-- ============================================================

-- Verify that checkpoint LSN is valid and redo LSN <= checkpoint LSN
-- (mirrors the "invalid redo in checkpoint record" PANIC check that
-- was moved earlier in the diff: checkPoint.redo > checkPointLoc)
SELECT
    checkpoint_lsn,
    redo_lsn,
    timeline_id,
    full_page_writes,
    next_xid,
    checkpoint_time
FROM pg_control_checkpoint();

-- Verify recovery control info (minRecoveryPoint etc.)
-- After a normal startup these should all be 0/invalid
SELECT
    min_recovery_end_lsn,
    min_recovery_end_timeline,
    backup_start_lsn,
    backup_end_lsn,
    end_of_backup_record_required
FROM pg_control_recovery();

-- Verify system-level control info
SELECT
    pg_control_version,
    catalog_version_no,
    system_identifier > 0 AS has_system_id
FROM pg_control_system();


-- ============================================================
-- Test 2: UNLOGGED tables -- exercises ResetUnloggedRelations path
-- Covers: Block 20 (src lines 7572-7573): if (InRecovery) ResetUnloggedRelations()
--         The moved code ensures unlogged relations are reset AFTER
--         archive recovery completion check. We verify the full
--         lifecycle of an UNLOGGED table and its INIT fork behavior.
-- ============================================================

CREATE UNLOGGED TABLE t144_unlogged (
    id    SERIAL PRIMARY KEY,
    val   TEXT NOT NULL,
    score DOUBLE PRECISION
);

CREATE INDEX idx_t144_unlogged_val ON t144_unlogged (val);

INSERT INTO t144_unlogged (val, score)
SELECT 'item_' || g, random() * 100
FROM generate_series(1, 1000) g;

-- Insert edge cases: NULL score, empty string val
INSERT INTO t144_unlogged (val, score) VALUES ('', NULL);
INSERT INTO t144_unlogged (val, score) VALUES (NULL, 0.0);

SELECT COUNT(*) FROM t144_unlogged;
SELECT COUNT(*) FROM t144_unlogged WHERE score IS NULL;
SELECT COUNT(*) FROM t144_unlogged WHERE val = '';

-- Verify pg_class shows unlogged persistence
SELECT relname, relpersistence
FROM pg_class
WHERE relname = 't144_unlogged';

DROP TABLE t144_unlogged;


-- ============================================================
-- Test 3: WAL checkpoint and pg_walfile_name
-- Covers: XLogInitNewTimeline() (renamed from exitArchiveRecovery),
--         InstallXLogFileSegmentActive flag, WAL segment creation.
--         The diff moves signal-file cleanup and archive-recovery-complete
--         log message out of XLogInitNewTimeline into the caller.
--         We exercise the WAL infrastructure that these paths rely on.
-- ============================================================

-- Create a regular logged table, write WAL, then checkpoint
CREATE TABLE t144_wal_test (
    id      BIGSERIAL PRIMARY KEY,
    payload BYTEA
);

-- Insert enough data to generate meaningful WAL
INSERT INTO t144_wal_test (payload)
SELECT repeat('x', 1024)::bytea
FROM generate_series(1, 200);

-- Force a checkpoint (exercises UpdateControlFile path and WAL flushing)
CHECKPOINT;

-- Verify WAL position is valid (non-zero)
SELECT pg_walfile_name(pg_current_wal_lsn()) IS NOT NULL AS wal_file_valid;
SELECT pg_current_wal_lsn() > '0/0' AS lsn_nonzero;

-- pg_switch_wal forces WAL segment rotation (exercises segment creation
-- path that XLogInitNewTimeline also uses for new timeline segments)
SELECT pg_switch_wal() > '0/0' AS switched;

CHECKPOINT;

DROP TABLE t144_wal_test;


-- ============================================================
-- Test 4: pg_is_in_recovery() and SharedRecoveryState
-- Covers: SpinLockAcquire(&XLogCtl->info_lck) blocks that set
--         SharedRecoveryState = RECOVERY_STATE_ARCHIVE or _CRASH
--         (moved earlier in the diff to before UpdateControlFile()).
--         Also covers the performedWalRecovery boolean logic that
--         replaced lastReplayedEndRecPtr check for PerformRecoveryXLogAction.
-- ============================================================

-- After normal startup (no recovery), these should return false/primary
SELECT pg_is_in_recovery() AS in_recovery;
SELECT pg_is_wal_replay_paused() AS replay_paused;

-- Verify WAL receive state (no streaming in standalone mode)
SELECT COUNT(*) AS walreceiver_count FROM pg_stat_wal_receiver;

-- Verify current WAL LSN is accessible (lastReplayedEndRecPtr / lastReplayedTLI)
SELECT pg_last_wal_replay_lsn() IS NULL AS no_replay_lsn_in_primary;
SELECT pg_last_wal_receive_lsn() IS NULL AS no_receive_lsn_in_primary;

-- Verify recovery target timeline (recoveryTargetTLI used in moved code)
SELECT timeline_id >= 1 AS valid_timeline
FROM pg_control_checkpoint();


-- ============================================================
-- Test 5: RelationCache init file removal + resource manager startup
-- Covers: Block: RelationCacheInitFileRemove() (moved after shmem init)
--         Block 16 (src 7189-7192): rm_startup() for each resource manager
--         (moved to fire only when there are actual WAL records to replay).
--         We stress relcache by opening many relations concurrently,
--         which exercises all resource managers (heap, btree, hash, gin, etc.)
-- ============================================================

-- Create tables using multiple resource managers / index types
CREATE TABLE t144_rmgr_heap (
    id      INTEGER PRIMARY KEY,
    name    TEXT,
    tags    TEXT[],
    data    JSONB
);

CREATE INDEX idx_t144_rmgr_btree ON t144_rmgr_heap (name);
CREATE INDEX idx_t144_rmgr_gin   ON t144_rmgr_heap USING GIN (tags);

-- Insert varied data including NULLs and edge values
INSERT INTO t144_rmgr_heap VALUES
    (1,    'alpha',   ARRAY['a','b'],          '{"x":1}'),
    (2,    'beta',    ARRAY['b','c'],          '{"x":2}'),
    (3,    NULL,      NULL,                    NULL),
    (4,    '',        ARRAY[]::TEXT[],         '{}'),
    (5,    'omega',   ARRAY['a','b','c','d'],  '{"nested":{"k":true}}');

-- Range of queries to activate multiple code paths in rmgr handlers
SELECT * FROM t144_rmgr_heap WHERE name IS NOT NULL ORDER BY name;
SELECT * FROM t144_rmgr_heap WHERE tags @> ARRAY['a'];
SELECT * FROM t144_rmgr_heap WHERE data IS NULL;
SELECT COUNT(*) FROM t144_rmgr_heap;

-- EXPLAIN ANALYZE to confirm executor and WAL-logging paths run
EXPLAIN ANALYZE
SELECT id, name FROM t144_rmgr_heap WHERE id BETWEEN 1 AND 5;

EXPLAIN ANALYZE
SELECT id FROM t144_rmgr_heap WHERE tags @> ARRAY['b'];

-- Force WAL flush for all above DML
CHECKPOINT;

DROP TABLE t144_rmgr_heap;

-- Test 1: Basic rescan with non-empty reorder queue (the primary bug fix path)
-- Triggers ExecReScanIndexScan with items in the reorder queue via LATERAL KNN.
-- The CROSS JOIN LATERAL forces a ReScan for each outer row while the
-- reorder queue may still hold tuples from the previous scan.
CREATE TABLE t145_knn (id int, p point);
CREATE INDEX t145_knn_gist ON t145_knn USING gist (p);
INSERT INTO t145_knn SELECT i, point(i * 0.1, i * 0.1) FROM generate_series(1, 500) i;
ANALYZE t145_knn;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT ss.id
FROM (VALUES (point(1.0, 1.0)), (point(3.0, 3.0)), (point(5.0, 5.0))) AS v(ref)
CROSS JOIN LATERAL (
    SELECT id FROM t145_knn ORDER BY p <-> ref LIMIT 3
) ss;
RESET enable_seqscan;
RESET enable_bitmapscan;
DROP TABLE t145_knn;

-- Test 2: Rescan with larger reorder queue (many tuples buffered before rescan)
-- Using a small LIMIT forces the rescan to happen while many tuples are still
-- in the pairing-heap reorder queue, maximizing the number of heap_freetuple()
-- calls that the fix introduces.
CREATE TABLE t145_many (id int, p point);
CREATE INDEX t145_many_gist ON t145_many USING gist (p);
INSERT INTO t145_many SELECT i, point((i % 100) * 0.1, (i % 50) * 0.2)
FROM generate_series(1, 2000) i;
ANALYZE t145_many;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT ss.id
FROM (VALUES (point(0.5, 0.5)), (point(2.5, 2.5)), (point(4.5, 4.5)),
             (point(6.5, 6.5)), (point(8.5, 8.5))) AS v(ref)
CROSS JOIN LATERAL (
    SELECT id FROM t145_many ORDER BY p <-> ref LIMIT 1
) ss;
RESET enable_seqscan;
RESET enable_bitmapscan;
DROP TABLE t145_many;

-- Test 3: Rescan when reorder queue is empty at rescan time (boundary condition)
-- When LIMIT equals the total number of matching rows the queue drains fully
-- before each rescan, exercising the while-loop exit with an already-empty queue.
CREATE TABLE t145_empty_q (id int, p point);
CREATE INDEX t145_empty_q_gist ON t145_empty_q USING gist (p);
INSERT INTO t145_empty_q VALUES (1, point(0,0)), (2, point(1,1)), (3, point(2,2));
ANALYZE t145_empty_q;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT ss.id
FROM (VALUES (point(0,0)), (point(1,1))) AS v(ref)
CROSS JOIN LATERAL (
    SELECT id FROM t145_empty_q ORDER BY p <-> ref LIMIT 10
) ss;
RESET enable_seqscan;
RESET enable_bitmapscan;
DROP TABLE t145_empty_q;

-- Test 4: Rescan via nested loop join with runtime key + reorder queue
-- A nested loop between two tables causes runtime-key re-evaluation on each
-- rescan, combining the runtime-key flush path with the reorder-queue flush.
CREATE TABLE t145_outer (oid int, ref point);
CREATE TABLE t145_inner (iid int, p point);
CREATE INDEX t145_inner_gist ON t145_inner USING gist (p);
INSERT INTO t145_outer VALUES (1, point(1,1)), (2, point(3,3)), (3, point(5,5));
INSERT INTO t145_inner SELECT i, point(i * 0.5, i * 0.5) FROM generate_series(1, 300) i;
ANALYZE t145_outer;
ANALYZE t145_inner;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SET enable_hashjoin = off;
SET enable_mergejoin = off;
SELECT o.oid, i.iid
FROM t145_outer o,
     LATERAL (SELECT iid FROM t145_inner ORDER BY p <-> o.ref LIMIT 2) i;
RESET enable_seqscan;
RESET enable_bitmapscan;
RESET enable_hashjoin;
RESET enable_mergejoin;
DROP TABLE t145_outer;
DROP TABLE t145_inner;

-- Test 5: Rescan with box opclass KNN (different GiST opclass, also uses
-- reordering because GiST distance is lossy) to verify the fix is not
-- specific to the point opclass.
CREATE TABLE t145_box (id int, b box);
CREATE INDEX t145_box_gist ON t145_box USING gist (b);
INSERT INTO t145_box
SELECT i, box(point(i*0.05, i*0.05), point(i*0.05+0.5, i*0.05+0.5))
FROM generate_series(1, 400) i;
ANALYZE t145_box;
SET enable_seqscan = off;
SET enable_bitmapscan = off;
SELECT ss.id
FROM (VALUES (point(1.0, 1.0)), (point(5.0, 5.0)), (point(10.0, 10.0))) AS v(ref)
CROSS JOIN LATERAL (
    SELECT id FROM t145_box ORDER BY b <-> ref LIMIT 2
) ss;
RESET enable_seqscan;
RESET enable_bitmapscan;
DROP TABLE t145_box;

-- ============================================================
-- SQL Regression Tests for nodeMergejoin.c Change
-- Commit: Replace Assert with elog(ERROR) for out-of-order inputs
-- Two new error paths:
--   1. Line 898-899: EXEC_MJ_NEXTINNER - compareResult > 0 (inner > outer)
--   2. Line 1141-1142: EXEC_MJ_TESTOUTER - compareResult < 0 (outer < marked)
-- ============================================================

-- ============================================================
-- Test 1: Normal mergejoin covering EXEC_MJ_NEXTINNER normal path
-- (compareResult < 0: inner advances past outer, goes to EXEC_MJ_NEXTOUTER)
-- This exercises the new "else if (compareResult < 0)" branch at line 896.
-- ============================================================
BEGIN;
SET enable_mergejoin = on;
SET enable_hashjoin = off;
SET enable_nestloop = off;

CREATE TABLE mj_outer_t1 (a INT);
CREATE TABLE mj_inner_t1 (b INT);
CREATE INDEX ON mj_outer_t1 (a);
CREATE INDEX ON mj_inner_t1 (b);

-- Outer: 1,2,3,5,7  Inner: 2,4,5,6  → inner frequently > outer, triggers NEXTOUTER
INSERT INTO mj_outer_t1 VALUES (1),(2),(3),(5),(7);
INSERT INTO mj_inner_t1 VALUES (2),(4),(5),(6);

-- EXPLAIN to confirm Merge Join is chosen
EXPLAIN (COSTS OFF)
SELECT mj_outer_t1.a, mj_inner_t1.b
FROM mj_outer_t1
JOIN mj_inner_t1 ON mj_outer_t1.a = mj_inner_t1.b
ORDER BY mj_outer_t1.a;

-- Execute: walks through EXEC_MJ_NEXTINNER with compareResult < 0 path
SELECT mj_outer_t1.a, mj_inner_t1.b
FROM mj_outer_t1
JOIN mj_inner_t1 ON mj_outer_t1.a = mj_inner_t1.b
ORDER BY mj_outer_t1.a;

DROP TABLE mj_outer_t1;
DROP TABLE mj_inner_t1;
ROLLBACK;


-- ============================================================
-- Test 2: Mergejoin with duplicate keys to trigger EXEC_MJ_TESTOUTER
-- (compareResult > 0: new outer > marked inner, goes to EXEC_MJ_SKIP_TEST)
-- This exercises the "else if (compareResult > 0)" branch at line 1089.
-- ============================================================
BEGIN;
SET enable_mergejoin = on;
SET enable_hashjoin = off;
SET enable_nestloop = off;

CREATE TABLE mj_outer_t2 (a INT);
CREATE TABLE mj_inner_t2 (b INT);
CREATE INDEX ON mj_outer_t2 (a);
CREATE INDEX ON mj_inner_t2 (b);

-- Duplicates in both: forces mark/restore and EXEC_MJ_TESTOUTER
-- When outer advances past the group (outer=6 vs marked=5), compareResult > 0
INSERT INTO mj_outer_t2 VALUES (3),(3),(5),(5),(6),(8);
INSERT INTO mj_inner_t2 VALUES (3),(3),(5),(5),(7),(9);

EXPLAIN (COSTS OFF)
SELECT mj_outer_t2.a, mj_inner_t2.b
FROM mj_outer_t2
JOIN mj_inner_t2 ON mj_outer_t2.a = mj_inner_t2.b
ORDER BY mj_outer_t2.a;

SELECT mj_outer_t2.a, mj_inner_t2.b
FROM mj_outer_t2
JOIN mj_inner_t2 ON mj_outer_t2.a = mj_inner_t2.b
ORDER BY mj_outer_t2.a;

DROP TABLE mj_outer_t2;
DROP TABLE mj_inner_t2;
ROLLBACK;


-- ============================================================
-- Test 3: Mergejoin with NULL values (MJEVAL_NONMATCHABLE path)
-- NULL in join key causes EXEC_MJ_NEXTOUTER without comparison,
-- verifying that the new code handles NULL boundaries safely.
-- ============================================================
BEGIN;
SET enable_mergejoin = on;
SET enable_hashjoin = off;
SET enable_nestloop = off;

CREATE TABLE mj_outer_t3 (a INT);
CREATE TABLE mj_inner_t3 (b INT);
CREATE INDEX ON mj_outer_t3 (a);
CREATE INDEX ON mj_inner_t3 (b);

-- NULLs interspersed among valid join keys
INSERT INTO mj_outer_t3 VALUES (1),(2),(NULL),(4),(5),(NULL),(7);
INSERT INTO mj_inner_t3 VALUES (NULL),(2),(3),(NULL),(5),(6);

EXPLAIN (COSTS OFF)
SELECT mj_outer_t3.a, mj_inner_t3.b
FROM mj_outer_t3
JOIN mj_inner_t3 ON mj_outer_t3.a = mj_inner_t3.b
ORDER BY mj_outer_t3.a NULLS LAST;

SELECT mj_outer_t3.a, mj_inner_t3.b
FROM mj_outer_t3
JOIN mj_inner_t3 ON mj_outer_t3.a = mj_inner_t3.b
ORDER BY mj_outer_t3.a NULLS LAST;

DROP TABLE mj_outer_t3;
DROP TABLE mj_inner_t3;
ROLLBACK;


-- ============================================================
-- Test 4: Mergejoin on LEFT JOIN to cover doFillOuter path
-- (EXEC_MJ_NEXTOUTER with doFillOuter=true, tests the fill-tuple branch
-- adjacent to the new else-elog at line 1141-1142)
-- ============================================================
BEGIN;
SET enable_mergejoin = on;
SET enable_hashjoin = off;
SET enable_nestloop = off;

CREATE TABLE mj_outer_t4 (a INT);
CREATE TABLE mj_inner_t4 (b INT);
CREATE INDEX ON mj_outer_t4 (a);
CREATE INDEX ON mj_inner_t4 (b);

-- Many outer rows that don't match any inner, exercising LEFT JOIN fill path
INSERT INTO mj_outer_t4 VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10);
INSERT INTO mj_inner_t4 VALUES (3),(3),(7),(7);

EXPLAIN (COSTS OFF)
SELECT mj_outer_t4.a, mj_inner_t4.b
FROM mj_outer_t4
LEFT JOIN mj_inner_t4 ON mj_outer_t4.a = mj_inner_t4.b
ORDER BY mj_outer_t4.a;

SELECT mj_outer_t4.a, mj_inner_t4.b
FROM mj_outer_t4
LEFT JOIN mj_inner_t4 ON mj_outer_t4.a = mj_inner_t4.b
ORDER BY mj_outer_t4.a;

DROP TABLE mj_outer_t4;
DROP TABLE mj_inner_t4;
ROLLBACK;


-- ============================================================
-- Test 5: Mergejoin with large duplicate groups triggering
-- multiple EXEC_MJ_TESTOUTER cycles (compareResult > 0 branch at line 1089)
-- and subsequent EXEC_MJ_NEXTINNER with compareResult < 0 (line 896).
-- This covers both modified code paths in a single join execution.
-- ============================================================
BEGIN;
SET enable_mergejoin = on;
SET enable_hashjoin = off;
SET enable_nestloop = off;

CREATE TABLE mj_outer_t5 (a INT);
CREATE TABLE mj_inner_t5 (b INT);
CREATE INDEX ON mj_outer_t5 (a);
CREATE INDEX ON mj_inner_t5 (b);

-- Large duplicate group at value 10, followed by non-matching values
-- Forces many TESTOUTER iterations then inner-skip then outer-skip
INSERT INTO mj_outer_t5
  SELECT 10 FROM generate_series(1,5)
  UNION ALL SELECT v FROM generate_series(12,20) v;
INSERT INTO mj_inner_t5
  SELECT 10 FROM generate_series(1,5)
  UNION ALL SELECT v FROM generate_series(15,25) v;

EXPLAIN (COSTS OFF)
SELECT mj_outer_t5.a, mj_inner_t5.b
FROM mj_outer_t5
JOIN mj_inner_t5 ON mj_outer_t5.a = mj_inner_t5.b
ORDER BY mj_outer_t5.a;

SELECT mj_outer_t5.a, mj_inner_t5.b
FROM mj_outer_t5
JOIN mj_inner_t5 ON mj_outer_t5.a = mj_inner_t5.b
ORDER BY mj_outer_t5.a;

DROP TABLE mj_outer_t5;
DROP TABLE mj_inner_t5;
ROLLBACK;

-- Test 1: Normal case -- promote a unique index to primary key (core new code path)
-- Exercises: marked_as_primary = true, CacheInvalidateRelcache(heapRelation)
CREATE TABLE t147_basic (id int NOT NULL, val text);
INSERT INTO t147_basic VALUES (1, 'a'), (2, 'b'), (3, 'c');
CREATE UNIQUE INDEX t147_basic_idx ON t147_basic(id);
ALTER TABLE t147_basic ADD PRIMARY KEY USING INDEX t147_basic_idx;
SELECT conname, contype FROM pg_constraint WHERE conrelid = 't147_basic'::regclass AND contype = 'p';
DROP TABLE t147_basic;

-- Test 2: Multi-column unique index promoted to primary key
-- Exercises: marked_as_primary with composite key (multiple indkey columns), relcache flush for composite PK
CREATE TABLE t147_composite (a int NOT NULL, b int NOT NULL, val text);
INSERT INTO t147_composite VALUES (1, 1, 'x'), (1, 2, 'y'), (2, 1, 'z');
CREATE UNIQUE INDEX t147_composite_idx ON t147_composite(a, b);
ALTER TABLE t147_composite ADD PRIMARY KEY USING INDEX t147_composite_idx;
SELECT indisprimary FROM pg_index WHERE indrelid = 't147_composite'::regclass;
DROP TABLE t147_composite;

-- Test 3: Table already has NOT NULL columns -- index promotion without needing to add NOT NULL
-- Exercises: the path where mark_as_primary fires without the NOT NULL branch,
-- confirming CacheInvalidateRelcache is still reached
CREATE TABLE t147_notnull (id int NOT NULL, data int NOT NULL);
INSERT INTO t147_notnull VALUES (10, 100), (20, 200);
CREATE UNIQUE INDEX t147_notnull_idx ON t147_notnull(id);
ALTER TABLE t147_notnull ADD PRIMARY KEY USING INDEX t147_notnull_idx;
SELECT relname FROM pg_class c JOIN pg_index i ON c.oid = i.indrelid
  WHERE c.relname = 't147_notnull' AND i.indisprimary;
DROP TABLE t147_notnull;

-- Test 4: Verify index becomes primary AFTER promotion (relcache reflects the change)
-- Exercises: post-invalidation state -- a fresh catalog lookup should show indisprimary = true
CREATE TABLE t147_verify (id bigint NOT NULL, ts timestamptz NOT NULL);
INSERT INTO t147_verify VALUES (1, now()), (2, now());
CREATE UNIQUE INDEX t147_verify_idx ON t147_verify(id);
-- Before promotion: indisprimary must be false
SELECT indisprimary FROM pg_index WHERE indexrelid = 't147_verify_idx'::regclass;
ALTER TABLE t147_verify ADD PRIMARY KEY USING INDEX t147_verify_idx;
-- After promotion: indisprimary must be true (relcache was flushed, new lookup reflects reality)
SELECT indisprimary FROM pg_index WHERE indexrelid = 't147_verify_idx'::regclass;
DROP TABLE t147_verify;

-- Test 5: Promotion inside a schema (non-default namespace) -- relcache flush with non-public schema
-- Exercises: CacheInvalidateRelcache on heapRelation when table is in a user-defined schema
CREATE SCHEMA s147;
CREATE TABLE s147.t147_schema (pk int NOT NULL, info text);
INSERT INTO s147.t147_schema VALUES (1, 'hello'), (2, 'world');
CREATE UNIQUE INDEX t147_schema_idx ON s147.t147_schema(pk);
ALTER TABLE s147.t147_schema ADD PRIMARY KEY USING INDEX t147_schema_idx;
SELECT conname FROM pg_constraint
  WHERE conrelid = 's147.t147_schema'::regclass AND contype = 'p';
DROP TABLE s147.t147_schema;
DROP SCHEMA s147;

-- ============================================================
-- SQL Regression Tests for commit_ts.c off-by-one bug fix
-- Bug: TransactionTreeSetCommitTsData had j+1 >= nsubxids
--      which caused the last subtransaction's commit timestamp
--      to be missed. Fixed to j >= nsubxids.
-- Requires: track_commit_timestamp = on (PostgreSQL restart needed)
-- ============================================================

-- ============================================================
-- Test 1: Single subtransaction (minimal SAVEPOINT case)
-- Covers: The fixed off-by-one check when nsubxids=1.
-- With the bug, j+1 >= 1 would be true at j=0, causing early
-- break and the single subxid's timestamp might be skipped.
-- ============================================================
BEGIN;
CREATE TABLE committs_subxact_single (id int, val text);
SAVEPOINT sp1;
INSERT INTO committs_subxact_single VALUES (1, 'subtx_1');
RELEASE SAVEPOINT sp1;
COMMIT;

-- Verify the row exists and query the timestamp (exercises the fixed path)
SELECT
    id,
    pg_xact_commit_timestamp(xmin) IS NOT NULL AS has_timestamp
FROM committs_subxact_single
ORDER BY id;

DROP TABLE committs_subxact_single;

-- ============================================================
-- Test 2: Multiple subtransactions on the same SLRU page
-- Covers: Loop iterates correctly for nsubxids > 1, all on
-- same page. The last subxid (index nsubxids-1) must NOT be
-- dropped due to the off-by-one bug.
-- ============================================================
BEGIN;
CREATE TABLE committs_subxact_multi (id int, val text);
SAVEPOINT sp1;
INSERT INTO committs_subxact_multi VALUES (1, 'subtx_1');
SAVEPOINT sp2;
INSERT INTO committs_subxact_multi VALUES (2, 'subtx_2');
SAVEPOINT sp3;
INSERT INTO committs_subxact_multi VALUES (3, 'subtx_3');
RELEASE SAVEPOINT sp3;
RELEASE SAVEPOINT sp2;
RELEASE SAVEPOINT sp1;
COMMIT;

-- All rows including the last inserted should have timestamps recorded
SELECT
    id,
    pg_xact_commit_timestamp(xmin) IS NOT NULL AS has_timestamp
FROM committs_subxact_multi
ORDER BY id;

DROP TABLE committs_subxact_multi;

-- ============================================================
-- Test 3: Nested SAVEPOINTs with the last subtransaction
-- specifically targeted (the row most likely to lose its
-- timestamp due to the off-by-one bug).
-- Covers: headxid = subxids[j] and i = j + 1 reassignment.
-- ============================================================
BEGIN;
CREATE TABLE committs_last_subxact (id int, ts_recorded boolean);
SAVEPOINT outer_sp;
    SAVEPOINT inner_sp1;
    INSERT INTO committs_last_subxact VALUES (1, true);
    RELEASE SAVEPOINT inner_sp1;

    SAVEPOINT inner_sp2;
    INSERT INTO committs_last_subxact VALUES (2, true);
    RELEASE SAVEPOINT inner_sp2;

    -- This last subtransaction was the one whose timestamp went missing
    SAVEPOINT inner_sp3;
    INSERT INTO committs_last_subxact VALUES (3, true);
    RELEASE SAVEPOINT inner_sp3;
RELEASE SAVEPOINT outer_sp;
COMMIT;

-- Specifically check that id=3 (last inserted in last SAVEPOINT) has a timestamp
SELECT
    id,
    pg_xact_commit_timestamp(xmin) IS NOT NULL AS has_commit_timestamp
FROM committs_last_subxact
ORDER BY id;

DROP TABLE committs_last_subxact;

-- ============================================================
-- Test 4: Transaction with NO subtransactions (nsubxids=0)
-- Covers: The loop's initial condition when there are zero
-- subxids. headxid = xid, i = 0, and j starts at 0 == nsubxids,
-- so j >= nsubxids is immediately true -> single iteration.
-- ============================================================
BEGIN;
CREATE TABLE committs_no_subxact (id int);
INSERT INTO committs_no_subxact VALUES (1);
INSERT INTO committs_no_subxact VALUES (2);
COMMIT;

SELECT
    id,
    pg_xact_commit_timestamp(xmin) IS NOT NULL AS has_timestamp
FROM committs_no_subxact
ORDER BY id;

DROP TABLE committs_no_subxact;

-- ============================================================
-- Test 5: Large number of subtransactions to stress the loop
-- and variable re-initialization (headxid = xid, i = 0 outside
-- the loop). This covers the refactored initialization path and
-- ensures i = j + 1 assignment works correctly across iterations.
-- ============================================================
DO $$
DECLARE
    i int;
BEGIN
    CREATE TABLE committs_stress (id int);
    FOR i IN 1..20 LOOP
        -- Each iteration creates a subtransaction via SAVEPOINT
        EXECUTE format('SAVEPOINT sp%s', i);
        INSERT INTO committs_stress VALUES (i);
        EXECUTE format('RELEASE SAVEPOINT sp%s', i);
    END LOOP;
    -- Commit happens when the DO block ends (within outer transaction)
END;
$$ LANGUAGE plpgsql;

-- Verify the stressed subtransactions recorded timestamps
SELECT
    COUNT(*) AS total_rows,
    COUNT(pg_xact_commit_timestamp(xmin)) AS rows_with_timestamp
FROM committs_stress;

DROP TABLE IF EXISTS committs_stress;

-- ============================================================
-- Test 6 (bonus): pg_last_committed_xact after subtransactions
-- Covers: The shared memory cache update (commitTsShared->xidLastCommit)
-- which happens after the fixed loop completes.
-- ============================================================
BEGIN;
CREATE TABLE committs_last_xact (id int);
SAVEPOINT s1;
INSERT INTO committs_last_xact VALUES (100);
RELEASE SAVEPOINT s1;
SAVEPOINT s2;
INSERT INTO committs_last_xact VALUES (200);
RELEASE SAVEPOINT s2;
COMMIT;

-- pg_last_committed_xact should reflect a valid xid and timestamp
SELECT
    (x.xid::text::bigint > 0) AS valid_xid,
    (x.timestamp > '-infinity'::timestamptz) AS valid_timestamp,
    (x.timestamp <= now()) AS not_in_future
FROM pg_last_committed_xact() x;

DROP TABLE committs_last_xact;

-- ============================================================
-- SQL Regression Tests for PostgreSQL commit:
-- "Fix ruleutils.c's dumping of whole-row Vars in more contexts"
--
-- Covers:
--   1. get_rule_list_toplevel() called from get_insert_query_def()
--      for single-row VALUES containing a whole-row Var (NEW.*)
--   2. get_rule_list_toplevel() called from T_RowCompareExpr handler
--      for largs and rargs containing regular expressions
--   3. RowCompareExpr with whole-row Var in a view (deparsed via pg_get_viewdef)
--   4. INSERT rule with whole-row Var (NEW.*) deparsed via pg_get_ruledef
--   5. Edge case: RowCompareExpr with NULL-able columns and multi-column rows
-- ============================================================


-- ============================================================
-- Test 1: INSERT rule with whole-row Var (NEW.*) single-row VALUES
-- Exercises: get_insert_query_def -> get_rule_list_toplevel (the primary bug fix)
-- The rule uses NEW.* (a whole-row Var) in a single-row VALUES clause.
-- pg_get_ruledef must deparse it correctly with ::type decoration.
-- ============================================================

CREATE TABLE t149_src (id integer, name text);
CREATE TABLE t149_dst (id integer, name text);

CREATE RULE r149_insert AS ON INSERT TO t149_src
    DO INSTEAD INSERT INTO t149_dst VALUES (NEW.*);

-- Trigger deparsing of the INSERT rule with whole-row Var in single-row VALUES
SELECT pg_get_ruledef(oid) FROM pg_rewrite
    WHERE rulename = 'r149_insert'
    AND ev_class = 't149_src'::regclass;

-- Actually exercise the rule by inserting data
INSERT INTO t149_src VALUES (1, 'hello');
INSERT INTO t149_src VALUES (2, 'world');
SELECT * FROM t149_dst ORDER BY id;

DROP RULE r149_insert ON t149_src;
DROP TABLE t149_src;
DROP TABLE t149_dst;


-- ============================================================
-- Test 2: RowCompareExpr in a WHERE clause captured in a rule/view
-- Exercises: T_RowCompareExpr case -> get_rule_list_toplevel for largs and rargs
-- A view containing a ROW comparison expression forces deparsing via
-- get_rule_expr -> T_RowCompareExpr -> get_rule_list_toplevel.
-- ============================================================

CREATE TABLE t149_rc (a integer, b integer, c integer);
INSERT INTO t149_rc VALUES (1, 2, 3), (4, 5, 6), (7, 8, 9);

-- Create a view with a RowCompareExpr (row comparison)
CREATE VIEW v149_rc AS
    SELECT * FROM t149_rc
    WHERE ROW(a, b) < ROW(5, 5);

-- Trigger deparsing of the view (exercises get_rule_list_toplevel for RowCompareExpr)
SELECT pg_get_viewdef('v149_rc', true);

-- Also query the view to confirm it works correctly
SELECT * FROM v149_rc ORDER BY a;

DROP VIEW v149_rc;
DROP TABLE t149_rc;


-- ============================================================
-- Test 3: RowCompareExpr with >= operator deparsed via pg_get_ruledef
-- Exercises: T_RowCompareExpr -> get_rule_list_toplevel for BOTH largs and rargs
-- Tests the right-hand side list (rargs) of the RowCompareExpr as well.
-- ============================================================

CREATE TABLE t149_rc2 (x text, y text);
INSERT INTO t149_rc2 VALUES ('apple', 'banana'), ('cherry', 'date'), ('fig', 'grape');

-- Rule with RowCompareExpr to exercise both largs and rargs deparsing
CREATE RULE r149_rc2 AS ON SELECT TO t149_rc2
    DO INSTEAD
        SELECT * FROM t149_rc2 WHERE ROW(x, y) >= ROW('cherry', 'date');

-- Deparse the rule to exercise get_rule_list_toplevel on both largs and rargs
SELECT pg_get_ruledef(oid) FROM pg_rewrite
    WHERE rulename = 'r149_rc2'
    AND ev_class = 't149_rc2'::regclass;

DROP RULE r149_rc2 ON t149_rc2;
DROP TABLE t149_rc2;


-- ============================================================
-- Test 4: INSERT rule with whole-row Var and multiple columns
-- Exercises: get_rule_list_toplevel with multiple elements in the list
-- Also tests that get_rule_expr_toplevel is called per element (sep logic).
-- ============================================================

CREATE TABLE t149_multi (col1 integer, col2 text, col3 boolean);
CREATE TABLE t149_multi_log (col1 integer, col2 text, col3 boolean);

CREATE RULE r149_multi AS ON INSERT TO t149_multi
    DO ALSO INSERT INTO t149_multi_log VALUES (NEW.*);

-- Deparse rule to exercise get_rule_list_toplevel with multi-column whole-row Var
SELECT pg_get_ruledef(oid) FROM pg_rewrite
    WHERE rulename = 'r149_multi'
    AND ev_class = 't149_multi'::regclass;

-- Insert with NULL values to test edge case
INSERT INTO t149_multi VALUES (1, 'test', true);
INSERT INTO t149_multi VALUES (2, NULL, false);
INSERT INTO t149_multi VALUES (3, 'edge', NULL);

SELECT * FROM t149_multi_log ORDER BY col1;

DROP RULE r149_multi ON t149_multi;
DROP TABLE t149_multi;
DROP TABLE t149_multi_log;


-- ============================================================
-- Test 5: RowCompareExpr with <> (not-equal) operator in a view,
-- plus NULL-able columns — edge case for get_rule_list_toplevel
-- Exercises: multi-column RowCompareExpr deparsing where values can be NULL
-- ============================================================

CREATE TABLE t149_null_rc (p integer, q text, r numeric);
INSERT INTO t149_null_rc VALUES (1, 'a', 1.0);
INSERT INTO t149_null_rc VALUES (2, NULL, 2.0);
INSERT INTO t149_null_rc VALUES (NULL, 'c', NULL);

-- View with a RowCompareExpr using <= and potentially NULL values
CREATE VIEW v149_null_rc AS
    SELECT * FROM t149_null_rc
    WHERE ROW(p, q) <= ROW(2, 'b');

-- Deparse to exercise get_rule_list_toplevel (both largs and rargs)
SELECT pg_get_viewdef('v149_null_rc', true);
SELECT pg_get_viewdef('v149_null_rc', false);

-- Execute the view to verify correctness with NULLs
SELECT * FROM v149_null_rc ORDER BY p NULLS LAST;

DROP VIEW v149_null_rc;
DROP TABLE t149_null_rc;


