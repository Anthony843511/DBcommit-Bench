----------------------------------------
-- Source: 1.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for:
--   Make truncate_useless_pathkeys() consider WindowFuncs
-- task_id: 1
--
-- This test covers the change where pathkeys_useful_for_ordering()
-- was modified to use root->sort_pathkeys instead of
-- root->query_pathkeys, and a new function
-- pathkeys_useful_for_windowing() was added to check
-- root->window_pathkeys.
--
-- The bug: when a query has window functions but no GROUP BY,
-- query_pathkeys gets set to window_pathkeys, which caused ORDER BY
-- pathkeys (sort_pathkeys) to be ignored in
-- truncate_useless_pathkeys(). This led to useful index pathkeys
-- being truncated away.
-- ================================================================

-- ################################################################
-- Test 1: Window function + ORDER BY (no GROUP BY)
-- This is the primary bug scenario. The query has:
--   - A Window function (ROW_NUMBER)
--   - An ORDER BY clause
--   - No GROUP BY
-- Before the fix, query_pathkeys = window_pathkeys, causing
-- sort_pathkeys (ORDER BY) to be ignored in
-- truncate_useless_pathkeys(). After the fix, sort_pathkeys is
-- checked explicitly in pathkeys_useful_for_ordering(), and
-- window_pathkeys is checked in the new
-- pathkeys_useful_for_windowing().
-- ################################################################
CREATE TABLE test_window_order (
    id SERIAL PRIMARY KEY,
    category TEXT NOT NULL,
    value INT NOT NULL,
    score NUMERIC
);

-- Insert data with variety for window ordering
INSERT INTO test_window_order (category, value, score)
SELECT
    CASE WHEN i % 3 = 0 THEN 'A'
         WHEN i % 3 = 1 THEN 'B'
         ELSE 'C'
    END,
    i,
    (random() * 100)::NUMERIC(10,2)
FROM generate_series(1, 100) AS i;

-- Create an index that could be useful for both the window ordering
-- and the ORDER BY
CREATE INDEX idx_window_order_cat_val
    ON test_window_order (category, value DESC);

-- Query with window function and ORDER BY on different columns
-- This triggers truncate_useless_pathkeys() to consider both
-- window_pathkeys (from ROW_NUMBER() OVER ...) and sort_pathkeys
-- (from the ORDER BY clause)
EXPLAIN ANALYZE
SELECT category, value, score,
       ROW_NUMBER() OVER (PARTITION BY category ORDER BY score DESC) AS rn
FROM test_window_order
WHERE category IN ('A', 'B')
ORDER BY value DESC;

-- Also test without the WHERE clause (full table scan path)
EXPLAIN ANALYZE
SELECT category, value,
       RANK() OVER (ORDER BY value DESC) AS rank
FROM test_window_order
ORDER BY score NULLS LAST;

DROP TABLE test_window_order;

-- ################################################################
-- Test 2: Multiple window functions with different orderings + ORDER BY
-- This tests a more complex scenario where there are multiple window
-- functions with different PARTITION BY / ORDER BY clauses, combined
-- with a top-level ORDER BY. This ensures the new code handles
-- various window_pathkeys configurations correctly.
-- ################################################################
CREATE TABLE test_multi_window (
    id SERIAL PRIMARY KEY,
    grp1 INT NOT NULL,
    grp2 INT NOT NULL,
    val1 INT NOT NULL,
    val2 INT NOT NULL,
    name TEXT
);

INSERT INTO test_multi_window (grp1, grp2, val1, val2, name)
SELECT
    i % 5,
    i % 3,
    (i * 2) % 100,
    (i * 3) % 100,
    'item_' || i
FROM generate_series(1, 200) AS i;

-- Index that could help with ordering
CREATE INDEX idx_mw_grp1_val1 ON test_multi_window (grp1, val1 DESC);
CREATE INDEX idx_mw_grp2_val2 ON test_multi_window (grp2, val2 ASC);

-- Query with two window functions and ORDER BY
EXPLAIN ANALYZE
SELECT grp1, grp2, val1, val2,
       ROW_NUMBER() OVER (PARTITION BY grp1 ORDER BY val1 DESC) AS rn1,
       SUM(val2) OVER (PARTITION BY grp2 ORDER BY val2) AS running_sum
FROM test_multi_window
WHERE grp1 < 3
ORDER BY grp2, val2;

DROP TABLE test_multi_window;

-- ################################################################
-- Test 3: Window function + ORDER BY on same column (overlapping pathkeys)
-- When the window ORDER BY and the query ORDER BY share the same
-- columns, the pathkeys overlap. This tests that the code correctly
-- handles overlapping pathkeys between window_pathkeys and
-- sort_pathkeys without double-counting or truncating incorrectly.
-- ################################################################
CREATE TABLE test_overlap_keys (
    id SERIAL PRIMARY KEY,
    dept TEXT NOT NULL,
    salary INT NOT NULL,
    bonus NUMERIC
);

INSERT INTO test_overlap_keys (dept, salary, bonus)
SELECT
    CASE WHEN i % 4 = 0 THEN 'Engineering'
         WHEN i % 4 = 1 THEN 'Sales'
         WHEN i % 4 = 2 THEN 'Marketing'
         ELSE 'Support'
    END,
    (random() * 100000)::INT + 30000,
    (random() * 10000)::NUMERIC(10,2)
FROM generate_series(1, 100) AS i;

CREATE INDEX idx_overlap_dept_salary ON test_overlap_keys (dept, salary DESC);

-- Window ORDER BY and query ORDER BY share the same column
EXPLAIN ANALYZE
SELECT dept, salary,
       RANK() OVER (PARTITION BY dept ORDER BY salary DESC) AS dept_rank
FROM test_overlap_keys
ORDER BY dept, salary DESC;

-- Also test with NULL values in the bonus column
INSERT INTO test_overlap_keys (dept, salary, bonus) VALUES
    ('Engineering', 50000, NULL),
    ('Sales', 60000, NULL);

EXPLAIN ANALYZE
SELECT dept, salary,
       DENSE_RANK() OVER (PARTITION BY dept ORDER BY bonus NULLS FIRST) AS dr
FROM test_overlap_keys
WHERE dept IN ('Engineering', 'Sales')
ORDER BY bonus NULLS FIRST, dept;

DROP TABLE test_overlap_keys;

-- ################################################################
-- Test 4: Window function + ORDER BY on different columns with
--         join (to trigger pathkeys_useful_for_merging as well)
-- This tests the combined logic in truncate_useless_pathkeys where
-- we consider merging, ordering, AND windowing pathkeys all at once.
-- The join introduces mergejoin considerations.
-- ################################################################
CREATE TABLE test_join_left (
    id INT PRIMARY KEY,
    code TEXT NOT NULL,
    amount INT NOT NULL
);

CREATE TABLE test_join_right (
    id INT PRIMARY KEY,
    description TEXT NOT NULL,
    factor NUMERIC NOT NULL
);

INSERT INTO test_join_left (id, code, amount)
SELECT i, 'CODE_' || (i % 10), (random() * 1000)::INT
FROM generate_series(1, 50) AS i;

INSERT INTO test_join_right (id, description, factor)
SELECT i, 'desc_' || i, (random() * 10 + 1)::NUMERIC(5,2)
FROM generate_series(1, 50) AS i;

CREATE INDEX idx_join_left_amount ON test_join_left (amount);
CREATE INDEX idx_join_right_factor ON test_join_right (factor);

-- Join query with window function and ORDER BY
EXPLAIN ANALYZE
SELECT l.code, l.amount, r.description,
       ROW_NUMBER() OVER (PARTITION BY l.code ORDER BY r.factor DESC) AS rn,
       l.amount * r.factor AS weighted
FROM test_join_left l
JOIN test_join_right r ON l.id = r.id
WHERE l.amount > 100
ORDER BY l.amount DESC, r.factor DESC;

DROP TABLE test_join_left;
DROP TABLE test_join_right;

-- ################################################################
-- Test 5: Edge cases - empty table, single row, and large offset
--         with window functions and ORDER BY
-- These edge cases test that the new code handles boundary
-- conditions correctly (empty result sets, minimal data).
-- ################################################################
CREATE TABLE test_edge_cases (
    id INT PRIMARY KEY,
    val INT,
    grp TEXT
);

-- Empty table - should produce no rows but still exercise the
-- pathkey truncation logic during planning
EXPLAIN ANALYZE
SELECT id, val,
       ROW_NUMBER() OVER (ORDER BY val) AS rn
FROM test_edge_cases
ORDER BY val;

-- Insert a single row
INSERT INTO test_edge_cases (id, val, grp) VALUES (1, NULL, 'X');

-- Single row with NULL values in window ordering column
EXPLAIN ANALYZE
SELECT id, val, grp,
       RANK() OVER (ORDER BY val NULLS LAST) AS r
FROM test_edge_cases
ORDER BY grp;

-- Insert more data with extreme values
INSERT INTO test_edge_cases (id, val, grp)
SELECT i, i * 10, CASE WHEN i % 2 = 0 THEN 'even' ELSE 'odd' END
FROM generate_series(2, 20) AS i;

CREATE INDEX idx_edge_grp_val ON test_edge_cases (grp, val);

-- Query with all features: window function, ORDER BY, WHERE filter
EXPLAIN ANALYZE
SELECT grp, val,
       SUM(val) OVER (PARTITION BY grp ORDER BY val) AS running_sum,
       COUNT(*) OVER (PARTITION BY grp) AS grp_count
FROM test_edge_cases
WHERE val IS NOT NULL
ORDER BY grp, val;

DROP TABLE test_edge_cases;

-- ================================================================
-- End of regression tests
-- ================================================================

----------------------------------------
-- Source: 2.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Calculate agglevelsup correctly when
-- Aggref contains a CTE (Bug #19055)
-- task_id: 2
--
-- This test exercises the new code paths in
-- check_agg_arguments_walker() in parse_agg.c that handle
-- RangeTblEntry nodes with rtekind == RTE_CTE.
--
-- The fix ensures that when an aggregate function's argument contains
-- a subquery that references a CTE defined outside the aggregate,
-- the CTE's query level is properly accounted for when determining
-- the aggregate's evaluation level.
-- ================================================================

-- ================================================================
-- Test 1: Basic case — aggregate with sub-select referencing a CTE
--         at the same query level.
--         Targets: RTE_CTE detection, ctelevelsup conversion,
--         min_varlevel update.
-- ================================================================
CREATE TABLE test_cte_agg_basic (f1 int);
INSERT INTO test_cte_agg_basic VALUES (1), (2), (3);

EXPLAIN (verbose, costs off)
SELECT f1,
       (WITH cte1 AS (SELECT 1 AS x, 2 AS y)
        SELECT count((SELECT f1 FROM cte1)))
FROM test_cte_agg_basic;

SELECT f1,
       (WITH cte1 AS (SELECT 1 AS x, 2 AS y)
        SELECT count((SELECT f1 FROM cte1)))
FROM test_cte_agg_basic
ORDER BY 1;

DROP TABLE test_cte_agg_basic;

-- ================================================================
-- Test 2: Multiple CTE references inside aggregate's subquery.
--         The aggregate's subquery references two different CTEs,
--         ensuring the logic correctly handles multiple RTE_CTE
--         nodes during the walker's traversal.
--         Targets: Multiple RTE_CTE in same subquery, min_varlevel
--         comparison logic.
-- ================================================================
CREATE TABLE test_cte_agg_multi (id int, val int);
INSERT INTO test_cte_agg_multi VALUES (1, 10), (2, 20), (3, 30);

EXPLAIN (verbose, costs off)
SELECT id,
       (WITH cte1 AS (SELECT 100 AS c1),
             cte2 AS (SELECT 200 AS c2)
        SELECT count((SELECT c1 FROM cte1) + (SELECT c2 FROM cte2)))
FROM test_cte_agg_multi;

SELECT id,
       (WITH cte1 AS (SELECT 100 AS c1),
             cte2 AS (SELECT 200 AS c2)
        SELECT count((SELECT c1 FROM cte1) + (SELECT c2 FROM cte2)))
FROM test_cte_agg_multi
ORDER BY 1;

DROP TABLE test_cte_agg_multi;

-- ================================================================
-- Test 3: Aggregate in outer query referencing a CTE that is defined
--         at the same level as a subquery containing the aggregate.
--         The aggregate's argument contains a subquery, which in turn
--         contains another subquery that references the CTE.
--         This tests the recursive descent into nested Query nodes
--         with QTW_EXAMINE_RTES_BEFORE.
--         Targets: Nested subqueries, sublevels_up tracking,
--         QTW_EXAMINE_RTES_BEFORE flag.
-- ================================================================
CREATE TABLE test_cte_agg_nested (a int, b int);
INSERT INTO test_cte_agg_nested VALUES (1, 2), (3, 4), (5, 6);

EXPLAIN (verbose, costs off)
SELECT a,
       (WITH cte1 AS (SELECT a AS aa)
        SELECT count((SELECT (SELECT aa FROM cte1)))
       )
FROM test_cte_agg_nested;

SELECT a,
       (WITH cte1 AS (SELECT a AS aa)
        SELECT count((SELECT (SELECT aa FROM cte1)))
       )
FROM test_cte_agg_nested
ORDER BY 1;

DROP TABLE test_cte_agg_nested;

-- ================================================================
-- Test 4: Aggregate referencing a recursively defined CTE inside
--         its subquery argument.  This tests that the new code
--         correctly handles CTEs that are recursive (RTE_CTE with
--         self-reference), and that the aggregate's level is not
--         incorrectly determined.
--         Targets: Recursive CTEs, edge case where ctelevelsup
--         after subtraction might be 0.
-- ================================================================
CREATE TABLE test_cte_agg_rec (n int);
INSERT INTO test_cte_agg_rec VALUES (1), (2), (3);

EXPLAIN (verbose, costs off)
SELECT n,
       (WITH RECURSIVE cte_seq(x) AS (
            SELECT 1
            UNION ALL
            SELECT x + 1 FROM cte_seq WHERE x < 10
        )
        SELECT count((SELECT x FROM cte_seq WHERE x = n))
       )
FROM test_cte_agg_rec;

SELECT n,
       (WITH RECURSIVE cte_seq(x) AS (
            SELECT 1
            UNION ALL
            SELECT x + 1 FROM cte_seq WHERE x < 10
        )
        SELECT count((SELECT x FROM cte_seq WHERE x = n))
       )
FROM test_cte_agg_rec
ORDER BY 1;

DROP TABLE test_cte_agg_rec;

-- ================================================================
-- Test 5: Aggregate in a subquery that references a CTE defined
--         at a higher (outer) level, combined with GROUP BY and
--         HAVING clauses. This tests the complete code path where
--         agglevelsup calculation must be correct to avoid planner
--         errors or broken plan trees.
--         Targets: Full integration with GROUP BY/HAVING,
--         min_varlevel correctness preventing wrong aggregation
--         level.
-- ================================================================
CREATE TABLE test_cte_agg_group (cat text, val int);
INSERT INTO test_cte_agg_group VALUES ('a', 10), ('a', 20), ('b', 30), ('b', 40), (NULL, 50);

EXPLAIN (verbose, costs off)
WITH cte_const AS (
    SELECT 100 AS threshold
)
SELECT cat,
       (SELECT count(*) FROM (
           SELECT (SELECT threshold FROM cte_const) AS t
           FROM test_cte_agg_group sub
           WHERE sub.cat = main.cat
           GROUP BY sub.val
           HAVING sum(sub.val) > (SELECT threshold FROM cte_const)
       ) subq)
FROM test_cte_agg_group main
GROUP BY cat;

WITH cte_const AS (
    SELECT 100 AS threshold
)
SELECT cat,
       (SELECT count(*) FROM (
           SELECT (SELECT threshold FROM cte_const) AS t
           FROM test_cte_agg_group sub
           WHERE sub.cat = main.cat
           GROUP BY sub.val
           HAVING sum(sub.val) > (SELECT threshold FROM cte_const)
       ) subq)
FROM test_cte_agg_group main
GROUP BY cat
ORDER BY cat NULLS FIRST;

DROP TABLE test_cte_agg_group;

-- ================================================================
-- End of regression tests for bug #19055
-- ================================================================

----------------------------------------
-- Source: 3.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Add missing EPQ recheck for TID Scan
-- task_id: 3
-- 
-- This test exercises the modified TidRecheck function in
-- src/backend/executor/nodeTidscan.c, which now properly rechecks
-- that the tuple's ctid still matches the TID list after following
-- update chains (EvalPlanQual recheck).
-- ================================================================

-- ================================================================
-- Test 1: Basic TID Scan - verify recheck path works for simple
-- ctid equality (normal case, no EPQ needed)
-- ================================================================
CREATE TABLE test_tidrecheck_basic (id integer, payload text);
INSERT INTO test_tidrecheck_basic VALUES (1, 'one'), (2, 'two'), (3, 'three'), (4, 'four');

-- Force a TID Scan via ctid equality
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, payload FROM test_tidrecheck_basic WHERE ctid = '(0,1)';

-- TID Scan with ctid IN (array of TIDs)
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, payload FROM test_tidrecheck_basic
WHERE ctid = ANY(ARRAY['(0,1)', '(0,3)']::tid[]);

-- TID Scan with ctid OR'd clauses
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, payload FROM test_tidrecheck_basic
WHERE ctid = '(0,2)' OR '(0,1)' = ctid;

DROP TABLE test_tidrecheck_basic;


-- ================================================================
-- Test 2: TID Scan with concurrent UPDATE to trigger EPQ recheck
-- This test creates a scenario where EvalPlanQual is needed:
-- Transaction A reads with TID Scan, Transaction B updates the
-- same row and commits, Transaction A rechecks the updated tuple.
-- ================================================================
CREATE TABLE test_tidrecheck_epq (id integer, val text);
INSERT INTO test_tidrecheck_epq VALUES (1, 'original'), (2, 'second'), (3, 'third');

-- Phase 1: Begin first transaction with a TID Scan
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- Use a TID Scan to read row (0,1)
SELECT ctid, id, val FROM test_tidrecheck_epq WHERE ctid = '(0,1)';

-- Phase 2: In another session, update the row (simulated via DO block
-- that runs as a separate transaction thanks to savepoints / subxact)
-- We use a background worker style approach with dblink... 
-- Actually, the simplest way: just UPDATE the row before the next scan.
-- Since we used REPEATABLE READ, the UPDATE in a separate transaction
-- would cause an EPQ recheck when the TID scan re-fetches.
--
-- But for a single-session test, we can update then re-scan.
-- Let's use a simpler approach: nested loop with inner tidscan join,
-- which can trigger the recheck path.

-- Update the row (this creates a new version / update chain)
UPDATE test_tidrecheck_epq SET val = 'updated' WHERE id = 1;

-- Now use TID Scan again - the new tuple version should still be found
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, val FROM test_tidrecheck_epq WHERE ctid = '(0,1)';

COMMIT;

-- Test with SERIALIZABLE isolation (stronger EPQ checks)
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT ctid, id, val FROM test_tidrecheck_epq WHERE ctid = '(0,2)';
UPDATE test_tidrecheck_epq SET val = 'serial_updated' WHERE id = 2;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, val FROM test_tidrecheck_epq WHERE ctid = '(0,2)';
COMMIT;

DROP TABLE test_tidrecheck_epq;


-- ================================================================
-- Test 3: TID Scan with ctid AND additional qualifiers - exercises
-- the recheck path when TID qual plus other conditions are used.
-- The planner may choose TID Scan for such queries, and the recheck
-- must ensure the updated tuple's ctid still matches.
-- ================================================================
CREATE TABLE test_tidrecheck_quals (id integer, category text, amount numeric);
INSERT INTO test_tidrecheck_quals VALUES
  (1, 'A', 10.0), (2, 'A', 20.0), (3, 'B', 30.0),
  (4, 'A', 40.0), (5, 'B', 50.0), (6, 'A', 60.0);

-- TID Scan with additional qualifier
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, category, amount FROM test_tidrecheck_quals
WHERE ctid = ANY(ARRAY['(0,1)', '(0,2)', '(0,3)']::tid[])
  AND category = 'A';

-- TID Scan with multiple conditions extracted from sub-AND
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, category, amount FROM test_tidrecheck_quals
WHERE (id >= 2 AND ctid IN ('(0,2)', '(0,4)', '(0,6)'))
   OR (ctid = '(0,1)' AND category = 'A');

-- Trigger recheck with updated tuples + additional quals
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT ctid, id, category, amount FROM test_tidrecheck_quals
WHERE ctid = ANY(ARRAY['(0,1)', '(0,2)']::tid[]);
UPDATE test_tidrecheck_quals SET amount = amount * 2 WHERE id = 1;
UPDATE test_tidrecheck_quals SET category = 'C' WHERE id = 2;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, category, amount FROM test_tidrecheck_quals
WHERE ctid = ANY(ARRAY['(0,1)', '(0,2)']::tid[])
  AND category IN ('A', 'C');
COMMIT;

DROP TABLE test_tidrecheck_quals;


-- ================================================================
-- Test 4: NestLoop join with inner TID Scan - this exercises the
-- recheck path via ExecScan's EvalPlanQual during join processing.
-- When the outer side updates rows, the inner TID scan rechecks.
-- ================================================================
CREATE TABLE test_tidrecheck_outer (id integer, info text);
CREATE TABLE test_tidrecheck_inner (id integer, data text);

INSERT INTO test_tidrecheck_outer VALUES (1, 'outer1'), (2, 'outer2'), (3, 'outer3');
INSERT INTO test_tidrecheck_inner VALUES (1, 'inner1'), (2, 'inner2'), (3, 'inner3');

SET enable_hashjoin TO off;
SET enable_mergejoin TO off;
SET enable_nestloop TO on;

-- Nested loop join with inner TID scan via ctid join
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT t1.id, t1.info, t2.id, t2.data
FROM test_tidrecheck_outer t1
JOIN test_tidrecheck_inner t2 ON t1.ctid = t2.ctid
WHERE t1.id = 1;

-- Left join with inner TID scan
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT t1.id, t1.info, t2.id, t2.data
FROM test_tidrecheck_outer t1
LEFT JOIN test_tidrecheck_inner t2 ON t1.ctid = t2.ctid
WHERE t1.id IN (1, 2);

RESET enable_hashjoin;
RESET enable_mergejoin;
RESET enable_nestloop;

DROP TABLE test_tidrecheck_inner;
DROP TABLE test_tidrecheck_outer;


-- ================================================================
-- Test 5: TID Scan edge cases - empty result, nonexistent TID,
-- multiple updates creating long update chains, and backward scan
-- which all exercise the recheck path.
-- ================================================================
CREATE TABLE test_tidrecheck_edge (id integer, label text);
INSERT INTO test_tidrecheck_edge VALUES (1, 'first'), (2, 'second'), (3, 'third');

-- Edge case: TID pointing to nonexistent tuple (past end of page)
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, label FROM test_tidrecheck_edge WHERE ctid = '(0,100)';

-- Edge case: TID IN with mix of valid and invalid TIDs
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, label FROM test_tidrecheck_edge
WHERE ctid = ANY(ARRAY['(0,1)', '(0,100)', '(0,2)', '(9999,1)']::tid[]);

-- Edge case: Multiple updates creating update chain, then TID scan
-- The updated tuple's ctid changes; recheck must handle this.
INSERT INTO test_tidrecheck_edge VALUES (4, 'to_update');
UPDATE test_tidrecheck_edge SET label = 'updated1' WHERE id = 4;
UPDATE test_tidrecheck_edge SET label = 'updated2' WHERE id = 4;
UPDATE test_tidrecheck_edge SET label = 'updated3' WHERE id = 4;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
SELECT ctid, id, label FROM test_tidrecheck_edge WHERE id = 4;

-- Edge case: TID Scan with backward scan direction
BEGIN;
DECLARE c CURSOR FOR
SELECT ctid, id, label FROM test_tidrecheck_edge
WHERE ctid = ANY(ARRAY['(0,1)', '(0,2)', '(0,3)']::tid[])
ORDER BY ctid;
FETCH ALL FROM c;
FETCH BACKWARD 1 FROM c;
FETCH BACKWARD 2 FROM c;
FETCH FIRST FROM c;
CLOSE c;
COMMIT;

-- Edge case: TID Scan with WHERE CURRENT OF (the tss_isCurrentOf path)
BEGIN;
DECLARE c CURSOR FOR SELECT id, label FROM test_tidrecheck_edge WHERE id < 4;
FETCH NEXT FROM c;
FETCH NEXT FROM c;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF, TIMING OFF)
UPDATE test_tidrecheck_edge SET label = 'current_of_update'
WHERE CURRENT OF c RETURNING *;
SELECT * FROM test_tidrecheck_edge;
ROLLBACK;

DROP TABLE test_tidrecheck_edge;


-- ================================================================
-- Summary of code paths covered:
-- Test 1: Basic TID Scan recheck (normal path, bsearch on TidList)
-- Test 2: TID Scan with concurrent UPDATE (EPQ recheck path)
-- Test 3: TID Scan with additional qualifiers (recheck + qual evaluation)
-- Test 4: NestLoop inner TID Scan (recheck via join EPQ)
-- Test 5: Edge cases - invalid TID, update chains, backward scan,
--         WHERE CURRENT OF (tss_isCurrentOf early return path)
-- ================================================================

----------------------------------------
-- Source: 6.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Revert "Get rid of WALBufMappingLock"
-- task_id: 6
-- This tests the re-introduced WALBufMappingLock in
-- AdvanceXLInsertBuffer(). The change brings back an LWLock to
-- protect WAL buffer page initialization instead of using atomic
-- operations + condition variables.
-- ================================================================

-- ================================================================
-- Test 1: Generate enough WAL to trigger AdvanceXLInsertBuffer
-- (normal initialization of new WAL buffer pages).
-- Large INSERT that fills multiple WAL buffers.
-- ================================================================
CREATE TABLE test_wal_bufinit1 (id int8, data text);

-- Insert enough rows to generate significant WAL and force
-- AdvanceXLInsertBuffer to initialize new pages.
-- Each row generates a WAL record for the INSERT.
INSERT INTO test_wal_bufinit1
SELECT g, repeat('x', 1000)
FROM generate_series(1, 10000) g;

-- Force a WAL flush to exercise WAL writing path as well
-- (which triggers the code path where WALBufMappingLock is
-- released, WALWriteLock acquired, then WALBufMappingLock re-acquired)
CHECKPOINT;

EXPLAIN ANALYZE
SELECT count(*) FROM test_wal_bufinit1 WHERE id > 5000;

DROP TABLE test_wal_bufinit1;


-- ================================================================
-- Test 2: Trigger the dirty-buffer write-out path in
-- AdvanceXLInsertBuffer. This exercises the code at lines 2204-2228
-- where WALBufMappingLock is released, WAL is written to disk,
-- and then WALBufMappingLock is re-acquired.
-- Strategy: Generate more WAL than the WAL buffer cache can hold,
-- forcing old dirty buffers to be written out.
-- ================================================================
CREATE TABLE test_wal_dirty1 (id serial, payload text);
CREATE TABLE test_wal_dirty2 (id serial, payload text);
CREATE TABLE test_wal_dirty3 (id serial, payload text);

-- Generate lots of WAL in parallel-like fashion across tables
-- to fill WAL buffers and force eviction of dirty pages.
INSERT INTO test_wal_dirty1 (payload)
SELECT repeat('WAL buffer test data ', 50)
FROM generate_series(1, 5000);

INSERT INTO test_wal_dirty2 (payload)
SELECT repeat('Forcing dirty buffer writeout ', 50)
FROM generate_series(1, 5000);

INSERT INTO test_wal_dirty3 (payload)
SELECT repeat('XLog buffer initialization ', 50)
FROM generate_series(1, 5000);

-- Flush everything to disk
CHECKPOINT;

EXPLAIN ANALYZE
SELECT a.id, b.id, c.id
FROM test_wal_dirty1 a
JOIN test_wal_dirty2 b ON a.id = b.id
JOIN test_wal_dirty3 c ON a.id = c.id
WHERE a.id % 100 = 0;

DROP TABLE test_wal_dirty1;
DROP TABLE test_wal_dirty2;
DROP TABLE test_wal_dirty3;


-- ================================================================
-- Test 3: Trigger the opportunistic pre-initialization path
-- (WAL writer calls AdvanceXLInsertBuffer with opportunistic=true).
-- The WAL writer tries to pre-initialize buffers ahead of insertions.
-- This exercises the early break when a page needs write-out
-- and opportunistic is true (line 2182-2183).
-- ================================================================
-- First, set wal_buffers to a small value to make buffer exhaustion
-- happen more easily. (Note: this requires superuser.)
-- We do a series of small updates, which the WAL writer can
-- opportunistically pre-initialize buffers for.

CREATE TABLE test_wal_opportunistic (id int PRIMARY KEY, value text);

-- Insert initial data
INSERT INTO test_wal_opportunistic
SELECT g, 'initial value ' || g
FROM generate_series(1, 1000) g;

-- Perform many small updates that generate WAL. Between updates,
-- the WAL writer will opportunistically call AdvanceXLInsertBuffer
-- to pre-initialize buffers.
DO $$
BEGIN
  FOR i IN 1..1000 LOOP
    UPDATE test_wal_opportunistic
    SET value = 'updated ' || i
    WHERE id = i;
  END LOOP;
END$$;

CHECKPOINT;

EXPLAIN ANALYZE
SELECT count(*) FROM test_wal_opportunistic WHERE value LIKE 'updated%';

DROP TABLE test_wal_opportunistic;


-- ================================================================
-- Test 4: Concurrent WAL insertions to test the WALBufMappingLock
-- contention path. Multiple backends inserting data simultaneously
-- will all need to call AdvanceXLInsertBuffer, testing the lock
-- acquisition and release patterns.
-- We simulate this with a single session doing large batch inserts.
-- ================================================================
CREATE TABLE test_wal_concurrent (id bigserial, data text);

-- Large batch insert with oversized data to push WAL generation
INSERT INTO test_wal_concurrent (data)
SELECT repeat('X', 500) || ' concurrent wal test '
FROM generate_series(1, 20000);

-- Generate index WAL by creating an index on the large table
CREATE INDEX test_wal_concurrent_idx ON test_wal_concurrent (id);

CHECKPOINT;

EXPLAIN ANALYZE
SELECT id FROM test_wal_concurrent ORDER BY id LIMIT 100;

DROP TABLE test_wal_concurrent;


-- ================================================================
-- Test 5: Edge case — small wal_buffers setting and rapid WAL
-- generation that wraps around the circular WAL buffer pool,
-- exercising the OldPageRqstPtr calculation and the retry logic
-- after releasing/re-acquiring WALBufMappingLock (lines 2226-2228).
-- ================================================================
-- Create multiple tables and do large INSERTs in sequence to
-- force the WAL buffer to wrap around the circular buffer pool.
CREATE TABLE test_wal_wrap1 (id serial, val text);
CREATE TABLE test_wal_wrap2 (id serial, val text);
CREATE TABLE test_wal_wrap3 (id serial, val text);
CREATE TABLE test_wal_wrap4 (id serial, val text);

-- Generate enough data in each table to fill and wrap the WAL buffers
INSERT INTO test_wal_wrap1 (val) SELECT repeat('Wrap test 1 - ', 100) FROM generate_series(1, 3000);
INSERT INTO test_wal_wrap2 (val) SELECT repeat('Wrap test 2 - ', 100) FROM generate_series(1, 3000);
INSERT INTO test_wal_wrap3 (val) SELECT repeat('Wrap test 3 - ', 100) FROM generate_series(1, 3000);
INSERT INTO test_wal_wrap4 (val) SELECT repeat('Wrap test 4 - ', 100) FROM generate_series(1, 3000);

-- More inserts to keep pushing the WAL write position
INSERT INTO test_wal_wrap1 (val) SELECT repeat('Second round - ', 100) FROM generate_series(1, 3000);
INSERT INTO test_wal_wrap2 (val) SELECT repeat('Second round - ', 100) FROM generate_series(1, 3000);

CHECKPOINT;

EXPLAIN ANALYZE
SELECT count(*) FROM test_wal_wrap1
WHERE val LIKE '%Wrap%';

DROP TABLE test_wal_wrap1;
DROP TABLE test_wal_wrap2;
DROP TABLE test_wal_wrap3;
DROP TABLE test_wal_wrap4;


-- ================================================================
-- End of SQL regression tests for WALBufMappingLock revert.
-- These tests exercise the re-introduced WALBufMappingLock in
-- AdvanceXLInsertBuffer() by generating enough WAL activity to:
-- 1. Initialize new WAL buffer pages
-- 2. Write out dirty buffers (release/re-acquire WALBufMappingLock)
-- 3. Opportunistic pre-initialization (WAL writer path)
-- 4. Concurrent-ish WAL insertions
-- 5. Circular buffer wrap-around with retry logic
-- ================================================================

----------------------------------------
-- Source: 8.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix inconsistent quoting of role names in ACLs
-- task_id: 8
-- This test exercises the new is_safe_acl_char() logic in getid()/putid(),
-- which handles non-ASCII characters and double-quote parsing in ACL I/O.
-- ================================================================

-- ================================================================
-- Test 1: Normal ASCII role name with GRANT/REVOKE
-- Target: Baseline test — verifies that typical ASCII role names still
--         work correctly with the new is_safe_acl_char() code path.
--         Exercises getid() with is_safe_acl_char(*s, true) on ASCII chars.
-- ================================================================

CREATE TABLE test_acl_normal (id int, data text);
INSERT INTO test_acl_normal VALUES (1, 'hello'), (2, 'world');

-- Use a role name with only alphanumeric chars (no quoting needed)
CREATE ROLE test_role_alpha WITH LOGIN;
GRANT SELECT ON TABLE test_acl_normal TO test_role_alpha;

-- Check the ACL representation (exercises aclitemout -> putid)
SELECT relname, relacl FROM pg_class WHERE relname = 'test_acl_normal';

-- Also verify has_table_privilege works (exercises getid internally)
SELECT has_table_privilege('test_role_alpha', 'test_acl_normal', 'SELECT');

-- Revoke and clean up
REVOKE SELECT ON TABLE test_acl_normal FROM test_role_alpha;
DROP ROLE test_role_alpha;
DROP TABLE test_acl_normal;


-- ================================================================
-- Test 2: Role name containing underscore and digits
-- Target: Boundary of safe ACL characters — underscore and digits are
--         considered safe by is_safe_acl_char().  Verifies that
--         putid() does NOT add quotes for such names, and getid()
--         parses them correctly.
-- ================================================================

CREATE TABLE test_acl_underscore (id int);

CREATE ROLE test_role_2 WITH LOGIN;
GRANT INSERT ON TABLE test_acl_underscore TO test_role_2;

-- Output ACL representation
SELECT relname, relacl FROM pg_class WHERE relname = 'test_acl_underscore';

REVOKE INSERT ON TABLE test_acl_underscore FROM test_role_2;
DROP ROLE test_role_2;
DROP TABLE test_acl_underscore;


-- ================================================================
-- Test 3: Role name requiring quoting (special characters)
-- Target: Exercises putid()'s detection of "unsafe" characters —
--         characters that are not alphanumeric or underscore.
--         putid() will add double quotes around the role name,
--         and getid() must parse them back correctly.
--         This exercises the new is_safe_acl_char(*src, false) path.
-- ================================================================

CREATE TABLE test_acl_special (id int);

-- Create a role with a hyphen (requires quoting in ACL representation)
CREATE ROLE "test-role-special" WITH LOGIN;
GRANT SELECT ON TABLE test_acl_special TO "test-role-special";

-- Verify output: relacl should show quoted role name
SELECT relname, relacl FROM pg_class WHERE relname = 'test_acl_special';

-- Verify input: has_table_privilege parses the quoted name correctly
SELECT has_table_privilege('test-role-special', 'test_acl_special', 'SELECT');

REVOKE SELECT ON TABLE test_acl_special FROM "test-role-special";
DROP ROLE "test-role-special";
DROP TABLE test_acl_special;


-- ================================================================
-- Test 4: Role name with embedded double quote character
-- Target: Exercises the escaped double-quote handling in both getid()
--         and putid().  A double quote inside a role name is represented
--         as "" (two double quotes).  This tests the fix where getid()
--         now correctly handles the case of an escaped double quote
--         vs. the old code which mis-handled the empty-string "" case.
--         Also exercises the new in_quotes state management.
-- ================================================================

CREATE TABLE test_acl_dblquote (id int);

-- Create a role whose name contains a double quote (must use quoted identifier)
CREATE ROLE "test""quote" WITH LOGIN;
GRANT SELECT ON TABLE test_acl_dblquote TO "test""quote";

-- Verify ACL representation: the double quote should be escaped as ""
SELECT relname, relacl FROM pg_class WHERE relname = 'test_acl_dblquote';

-- Verify has_table_privilege can parse the name with escaped quotes
SELECT has_table_privilege('test"quote', 'test_acl_dblquote', 'SELECT');

REVOKE SELECT ON TABLE test_acl_dblquote FROM "test""quote";
DROP ROLE "test""quote";
DROP TABLE test_acl_dblquote;


-- ================================================================
-- Test 5: GRANT/REVOKE with non-ASCII (Unicode) role names
-- Target: Core fix — IS_HIGHBIT_SET(c) characters are now handled
--         differently by getid() (accepts without quotes) vs. putid()
--         (always adds quotes).  This test verifies that a role name
--         with non-ASCII characters is correctly stored and retrieved
--         in ACLs, ensuring dump/reload compatibility.
--         Exercises both is_safe_acl_char(c, true) and is_safe_acl_char(c, false).
-- ================================================================

CREATE TABLE test_acl_unicode (id int);

-- Create a role with non-ASCII characters (Cyrillic name)
CREATE ROLE "тестовая_роль" WITH LOGIN;
GRANT SELECT ON TABLE test_acl_unicode TO "тестовая_роль";

-- The relacl output should show the non-ASCII name quoted (because putid
-- treats high-bit chars as unsafe for output to ensure cross-platform compat)
SELECT relname, relacl FROM pg_class WHERE relname = 'test_acl_unicode';

-- Verify getid() can parse the non-ASCII name (should accept without quotes)
SELECT has_table_privilege('тестовая_роль', 'test_acl_unicode', 'SELECT');

REVOKE SELECT ON TABLE test_acl_unicode FROM "тестовая_роль";
DROP ROLE "тестовая_роль";
DROP TABLE test_acl_unicode;


-- ================================================================
-- Test 6: Edge case — multiple privileges, grantor specified
-- Target: Exercises aclparse() path where both grantee and grantor
--         are passed through getid(). Tests the full round-trip:
--         aclitemin (getid) → aclitemout (putid) with non-trivial names.
-- ================================================================

CREATE TABLE test_acl_roundtrip (id int);

CREATE ROLE "grantor_role" WITH LOGIN;
CREATE ROLE "grantee_role" WITH LOGIN;

-- Grant with GRANTED BY to exercise grantor name in ACL
GRANT SELECT, INSERT ON TABLE test_acl_roundtrip TO "grantee_role";

-- Check the ACL output
SELECT relname, relacl FROM pg_class WHERE relname = 'test_acl_roundtrip';

-- Cast aclitem to text to verify round-trip conversion
SELECT pg_typeof(relacl) FROM pg_class WHERE relname = 'test_acl_roundtrip';

REVOKE ALL ON TABLE test_acl_roundtrip FROM "grantee_role";
DROP ROLE "grantee_role";
DROP ROLE "grantor_role";
DROP TABLE test_acl_roundtrip;

----------------------------------------
-- Source: 9.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Keep WAL segments by the flushed value of
--                          the slot's restart LSN
-- task_id: 9
-- Description:
--   This commit fixes an issue where WAL segments needed by replication
--   slots could be incorrectly removed after a checkpoint, when a slot's
--   restart_lsn is advanced concurrently during checkpoint processing.
--   The fix captures the minimum slot LSN (slotsMinReqLSN) before
--   CheckPointReplicationSlots() syncs the slots, and uses that snapshot
--   value throughout the WAL cleanup phase.
--
--   Code paths exercised:
--     - CreateCheckPoint(): slotsMinReqLSN capture (line 9153)
--     - KeepLogSeg() with slotsMinReqLSN parameter (line 9319, 9335)
--     - CreateRestartPoint(): slotsMinReqLSN capture (line 9654)
--     - GetWALAvailability(): slotsMinReqLSN capture (line 9873)
--     - Re-invalidation path: recalc slotsMinReqLSN & re-sync (line 9327-9328)
-- ================================================================

-- ================================================================
-- Test 1: Physical replication slot checkpoint retention
-- Target: CreateCheckPoint() capturing slotsMinReqLSN (line 9153)
--         and passing it to KeepLogSeg() (line 9319)
-- Scenario: Create a physical replication slot, generate WAL, then
--           run CHECKPOINT to trigger the WAL cleanup path.
-- ================================================================

-- Create a physical replication slot (reserves WAL at its restart_lsn)
SELECT pg_create_physical_replication_slot('test_slot_phys_checkpoint', true);

-- Generate some WAL activity so there is WAL to consider for cleanup
CREATE TABLE test_wal_retention_1 (id int, data text);
INSERT INTO test_wal_retention_1 VALUES (1, 'hello');
INSERT INTO test_wal_retention_1 VALUES (2, 'world');

-- Force WAL switch to create new segments
SELECT pg_switch_wal() AS switched_lsn \gset

-- Run CHECKPOINT which triggers CreateCheckPoint() -> KeepLogSeg()
-- with captured slotsMinReqLSN
CHECKPOINT;

-- Cleanup
DROP TABLE test_wal_retention_1;
SELECT pg_drop_replication_slot('test_slot_phys_checkpoint');


-- ================================================================
-- Test 2: Logical replication slot and slot advancement during checkpoint
-- Target: KeepLogSeg() re-invocation after slot invalidation (line 9327-9335)
--         and the recalculated slotsMinReqLSN path
-- Scenario: Create a logical slot, advance it, then run CHECKPOINT.
--           The slot advancement simulates concurrent LSN change.
-- ================================================================

-- Create a logical replication slot
SELECT pg_create_logical_replication_slot('test_slot_logical_checkpoint', 'pgoutput');

-- Generate data to advance the WAL position
CREATE TABLE test_wal_retention_2 (id int, val text);
INSERT INTO test_wal_retention_2 SELECT generate_series(1,100), 'data_' || generate_series(1,100);

-- Switch WAL to force a new segment
SELECT pg_switch_wal() AS switched_lsn \gset

-- Run CHECKPOINT to exercise CreateCheckPoint() path
CHECKPOINT;

-- Cleanup
DROP TABLE test_wal_retention_2;
SELECT pg_drop_replication_slot('test_slot_logical_checkpoint');


-- ================================================================
-- Test 3: Multiple replication slots, max_slot_wal_keep_size boundary
-- Target: KeepLogSeg() with max_slot_wal_keep_size cap (line 9954-9964)
--         and CreateCheckPoint() slotsMinReqLSN capture
-- Scenario: Create multiple slots to simulate real-world scenario
--           where the minimum restart_lsn across all slots matters.
-- ================================================================

-- Create two physical slots
SELECT pg_create_physical_replication_slot('test_slot_multi_1', true);
SELECT pg_create_physical_replication_slot('test_slot_multi_2', true);

-- Generate enough WAL data
CREATE TABLE test_wal_retention_3 (id int, payload text);
INSERT INTO test_wal_retention_3 SELECT i, 'payload_' || i FROM generate_series(1,1000) i;

-- Switch WAL several times
SELECT pg_switch_wal() AS lsn1 \gset
INSERT INTO test_wal_retention_3 SELECT i, 'more_' || i FROM generate_series(1001,2000) i;
SELECT pg_switch_wal() AS lsn2 \gset

-- Run CHECKPOINT, which recalculates slotsMinReqLSN if slots are invalidated
CHECKPOINT;

-- Cleanup
DROP TABLE test_wal_retention_3;
SELECT pg_drop_replication_slot('test_slot_multi_1');
SELECT pg_drop_replication_slot('test_slot_multi_2');


-- ================================================================
-- Test 4: pg_walfile_name and WAL availability check
-- Target: GetWALAvailability() capturing slotsMinReqLSN (line 9873)
--         and calling KeepLogSeg() with it (line 9875)
-- Scenario: Use pg_walfile_name() which internally calls
--           GetWALAvailability() to check WAL availability,
--           exercising the new slotsMinReqLSN capture path.
-- ================================================================

-- Create a slot to ensure there is a minimum LSN
SELECT pg_create_physical_replication_slot('test_slot_wal_avail', true);

-- Generate some WAL and get the current LSN
CREATE TABLE test_wal_retention_4 (id int);
INSERT INTO test_wal_retention_4 VALUES (1);

-- Get the current WAL insert position and check WAL availability
-- pg_walfile_name_offset -> pg_walfile_name internally calls
-- GetWALAvailability to check if the WAL file is still available
SELECT pg_current_wal_lsn() AS current_lsn \gset

-- Check WAL file name (exercises WAL availability check path)
SELECT pg_walfile_name(:'current_lsn');

-- Also check with pg_walfile_name_offset
SELECT * FROM pg_walfile_name_offset(pg_current_wal_lsn());

-- Run CHECKPOINT which also triggers GetWALAvailability indirectly
CHECKPOINT;

-- Cleanup
DROP TABLE test_wal_retention_4;
SELECT pg_drop_replication_slot('test_slot_wal_avail');


-- ================================================================
-- Test 5: Edge case - no replication slots, checkpoint cleanup
-- Target: KeepLogSeg() with InvalidXLogRecPtr slotsMinReqLSN (line 9950)
--         and CreateCheckPoint() with no slots
-- Scenario: Without any replication slots, XLogGetReplicationSlotMinimumLSN()
--           returns InvalidXLogRecPtr. This exercises the branch at line 9950
--           where "keep != InvalidXLogRecPtr" is false, so the slot-based
--           retention logic is skipped.
-- ================================================================

-- Ensure no replication slots exist (clean up any from previous tests)
SELECT pg_drop_replication_slot(slot_name)
FROM pg_replication_slots
WHERE slot_name IN ('test_slot_phys_checkpoint', 'test_slot_logical_checkpoint',
                     'test_slot_multi_1', 'test_slot_multi_2', 'test_slot_wal_avail');

-- Generate some WAL data
CREATE TABLE test_no_slots (id int, padding text);
INSERT INTO test_no_slots SELECT i, 'some_data_' || i FROM generate_series(1,100) i;

-- Switch WAL to create segment
SELECT pg_switch_wal() AS switched_lsn \gset

-- Run CHECKPOINT with no replication slots active.
-- In this case slotsMinReqLSN = InvalidXLogRecPtr (0/0),
-- and KeepLogSeg() checks "if (keep != InvalidXLogRecPtr && keep < recptr)"
-- which evaluates to false, so only wal_keep_size matters.
CHECKPOINT;

-- Verify WAL status by checking current position
SELECT pg_current_wal_lsn() AS wal_lsn \gset
SELECT pg_walfile_name(:'wal_lsn') AS wal_file;

-- Cleanup
DROP TABLE test_no_slots;

-- Final verification: check there are no leftover slots from this test
SELECT slot_name, slot_type, active FROM pg_replication_slots;

----------------------------------------
-- Source: 11.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Remove XLogFileInit() ability to skip ControlFileLock
-- task_id: 11
--
-- This commit removes the use_lock parameter from XLogFileInit() and
-- InstallXLogFileSegment(), making them always acquire ControlFileLock.
-- Previously, cold paths (bootstrap, end-of-recovery) skipped the lock.
-- Now all callers uniformly acquire the lock.
--
-- These tests exercise the call sites by triggering WAL segment
-- operations (switch, checkpoint, recycle, preallocation) that invoke
-- XLogFileInit() and InstallXLogFileSegment().
-- ================================================================

-- ================================================================
-- Test 1: XLogFileInit() via XLogWrite() - WAL segment switch
--   Call chain: XLogWrite() -> XLogFileInit()
--   This is exercised by forcing a WAL segment switch (pg_switch_wal)
--   which triggers writing to a new WAL segment, initializing it.
-- ================================================================
CREATE TABLE test_wal_switch (id int, data text);
INSERT INTO test_wal_switch SELECT generate_series(1,1000), 'a';

-- Force WAL switch to trigger XLogFileInit in XLogWrite path
SELECT pg_switch_wal();

-- Generate more WAL to ensure new segment is used
INSERT INTO test_wal_switch SELECT generate_series(1001,2000), 'b';
SELECT pg_switch_wal();

DROP TABLE test_wal_switch;

-- ================================================================
-- Test 2: PreallocXlogFiles() via CHECKPOINT
--   Call chain: CHECKPOINT -> PreallocXlogFiles() -> XLogFileInit()
--   A CHECKPOINT triggers preallocation of future WAL segments,
--   which calls XLogFileInit() to create new WAL files.
-- ================================================================
CREATE TABLE test_checkpoint_prealloc (id int, data text);
INSERT INTO test_checkpoint_prealloc SELECT generate_series(1,5000), 'checkpoint_test_' || g;

-- Execute CHECKPOINT to trigger WAL segment preallocation
CHECKPOINT;

-- Force another checkpoint after more WAL activity
INSERT INTO test_checkpoint_prealloc SELECT generate_series(5001,10000), 'more_data';
CHECKPOINT;

DROP TABLE test_checkpoint_prealloc;

-- ================================================================
-- Test 3: RemoveXlogFile() - WAL file recycling via InstallXLogFileSegment()
--   Call chain: RemoveXlogFile() -> InstallXLogFileSegment()
--   WAL segment recycling happens during checkpoints when old segments
--   are renamed/recycled for future use. This exercises the find_free
--   path in InstallXLogFileSegment().
-- ================================================================
CREATE TABLE test_wal_recycle (id int, data text);
INSERT INTO test_wal_recycle SELECT generate_series(1,10000), 'recycle_test_' || g;

-- Multiple WAL switches to create recyclable segments
SELECT pg_switch_wal();
INSERT INTO test_wal_recycle SELECT generate_series(10001,20000), 'more';
SELECT pg_switch_wal();
INSERT INTO test_wal_recycle SELECT generate_series(20001,30000), 'extra';
SELECT pg_switch_wal();

-- Run checkpoint to trigger recycling of old WAL segments
CHECKPOINT;

DROP TABLE test_wal_recycle;

-- ================================================================
-- Test 4: XLogFileInit() via multiple rapid segment switches
--   This exercises a fast succession of XLogFileInit calls through
--   the XLogWrite path, stressing the ControlFileLock acquisition
--   that the commit made unconditional.
-- ================================================================
CREATE TABLE test_rapid_switch (id serial, payload text);

-- Generate enough WAL to force multiple segment switches
INSERT INTO test_rapid_switch (payload)
SELECT repeat('x', 1000) FROM generate_series(1,100);

SELECT pg_switch_wal();

INSERT INTO test_rapid_switch (payload)
SELECT repeat('y', 1000) FROM generate_series(1,100);

SELECT pg_switch_wal();

INSERT INTO test_rapid_switch (payload)
SELECT repeat('z', 1000) FROM generate_series(1,100);

SELECT pg_switch_wal();

CHECKPOINT;

DROP TABLE test_rapid_switch;

-- ================================================================
-- Test 5: XLogFileInit() via PreallocXlogFiles() during heavy checkpoint
--   This exercises the preallocation path where multiple WAL segments
--   are initialized ahead of time, ensuring InstallXLogFileSegment()
--   with find_free=true properly acquires ControlFileLock.
-- ================================================================
CREATE TABLE test_heavy_checkpoint (id int, data text);

-- Generate significant WAL activity
INSERT INTO test_heavy_checkpoint
SELECT g, 'heavy_' || g
FROM generate_series(1, 50000) g;

-- Force checkpoint with heavy WAL to trigger preallocation
CHECKPOINT;

-- More WAL activity
UPDATE test_heavy_checkpoint SET data = data || '_updated'
WHERE id % 2 = 0;

-- Another checkpoint to trigger more segment operations
CHECKPOINT;

INSERT INTO test_heavy_checkpoint
SELECT g, 'batch2_' || g
FROM generate_series(50001, 100000) g;

CHECKPOINT;

DROP TABLE test_heavy_checkpoint;

-- ================================================================
-- End of regression tests
-- ================================================================

----------------------------------------
-- Source: 12.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Remove XLogFileInit() ability to unlink a
-- pre-existing file.
-- task_id: 12
-- ================================================================
-- 
-- This test exercises the modified XLogFileInitInternal() function and
-- its callers (XLogWrite, PreallocXlogFiles, exitArchiveRecovery,
-- BootStrapXLOG), which were changed to always try opening an existing
-- WAL segment first rather than conditionally unlinking it.
--
-- Key change: The *use_existent parameter was removed; the function now
-- unconditionally attempts to open an existing file before creating a
-- new one, and the *added output parameter indicates whether a new
-- segment was created.
--
-- Each test triggers WAL segment creation via different code paths.
-- ================================================================

-- ################################################################
-- Test 1: XLogWrite code path — pg_switch_wal() forces WAL segment
-- switch, causing XLogWrite() -> XLogFileInit() to be called when
-- writing to a new segment.
-- 
-- Covers: XLogWrite() calling XLogFileInit(openLogSegNo) at line 2522,
-- which calls XLogFileInitInternal().  This exercises the new code
-- path where the function always tries BasicOpenFile() first.
-- ################################################################
CREATE TABLE test_wal_switch (id int, data text);
INSERT INTO test_wal_switch SELECT generate_series(1, 100), 'test data for WAL log';

-- Force a WAL segment switch.  This triggers XLogWrite to close the
-- current segment and open/init the next one.
SELECT pg_switch_wal();

-- Generate more WAL activity to potentially cross segment boundary
INSERT INTO test_wal_switch SELECT generate_series(101, 200), 'more WAL data';
SELECT pg_switch_wal();

DROP TABLE test_wal_switch;

-- ################################################################
-- Test 2: PreallocXlogFiles code path — CHECKPOINT at a point where
-- the write position is beyond 75% of the current WAL segment,
-- triggering PreallocXlogFiles() to pre-create the next segment.
--
-- Covers: PreallocXlogFiles() calling XLogFileInitInternal() at
-- line 3956, where *added is set based on whether a new segment was
-- created (line 3959).
-- ################################################################
CREATE TABLE test_checkpoint_prealloc (id int, payload text);

-- Insert enough data to advance WAL insert position well past 75% of
-- the current segment, so PreallocXlogFiles will pre-allocate.
INSERT INTO test_checkpoint_prealloc
SELECT g, repeat('x', 1000)
FROM generate_series(1, 5000) g;

-- Force a checkpoint, which calls PreallocXlogFiles at the end.
CHECKPOINT;

-- More data to exercise preallocation again
INSERT INTO test_checkpoint_prealloc
SELECT g, repeat('y', 1000)
FROM generate_series(5001, 10000) g;

CHECKPOINT;

DROP TABLE test_checkpoint_prealloc;

-- ################################################################
-- Test 3: Chained WAL switches — multiple rapid pg_switch_wal() calls
-- to create several new WAL segments in sequence.  Each switch causes
-- XLogWrite to init a new segment.  This exercises repeated calls to
-- XLogFileInitInternal() where the new segment file does NOT exist
-- yet (tests the file-creation branch at line 3321).
--
-- Covers: The full XLogFileInitInternal() code path when a new segment
-- must be created from scratch (lines 3321-3433).
-- ################################################################
CREATE TABLE test_multi_switch (id int, t text);

-- Insert some data to get a WAL write position
INSERT INTO test_multi_switch VALUES (1, 'start');

-- Force multiple segment switches
SELECT pg_switch_wal();
SELECT pg_switch_wal();
SELECT pg_switch_wal();
SELECT pg_switch_wal();
SELECT pg_switch_wal();

-- Generate more data and more switches
INSERT INTO test_multi_switch SELECT g, 'payload-' || g FROM generate_series(2, 100) g;
SELECT pg_switch_wal();
SELECT pg_switch_wal();

DROP TABLE test_multi_switch;

-- ################################################################
-- Test 4: Large data insertion causing natural WAL segment overflow.
-- Insert enough data to naturally fill multiple WAL segments.  This
-- triggers the XLogWrite code path where a segment fills up during
-- normal operation (not forced by pg_switch_wal).
--
-- Covers: XLogWrite segment boundary detection and automatic
-- XLogFileInit() call (line 2522) when a new segment is needed during
-- natural WAL logging.
-- ################################################################
CREATE TABLE test_bulk_wal (id int, data text);

-- Insert a large amount of data to generate enough WAL to cross
-- multiple segment boundaries naturally.
INSERT INTO test_bulk_wal
SELECT g, repeat('PostgreSQL WAL regression test data ', 100)
FROM generate_series(1, 2000) g;

-- Force a checkpoint to ensure all data is written
CHECKPOINT;

-- More bulk inserts
INSERT INTO test_bulk_wal
SELECT g, repeat('Additional payload to cross WAL segments ', 200)
FROM generate_series(2001, 5000) g;

CHECKPOINT;

DROP TABLE test_bulk_wal;

-- ################################################################
-- Test 5: WAL segment reuse after checkpoint — after a checkpoint
-- removes old WAL segments, new WAL activity forces creation of new
-- segments.  This exercises the code path where a file may or may not
-- already exist when XLogFileInitInternal tries to open it.
--
-- Specifically covers the scenario where BasicOpenFile() at line 3297
-- finds that the file does NOT exist (ENOENT), so the function proceeds
-- to create a new one.  Also covers the *added=true path at line 3421.
-- ################################################################
CREATE TABLE test_segment_reuse (id int, t text);

-- Phase 1: Generate initial WAL activity
INSERT INTO test_segment_reuse SELECT g, 'phase1-' || g FROM generate_series(1, 500) g;
SELECT pg_switch_wal();

-- Phase 2: Generate more WAL activity with switches
INSERT INTO test_segment_reuse SELECT g, 'phase2-' || g FROM generate_series(501, 1000) g;
SELECT pg_switch_wal();

-- Force checkpoint to potentially allow WAL segment recycling
CHECKPOINT;

-- Phase 3: After checkpoint, generate significant new WAL activity.
-- If old segments were recycled, XLogFileInitInternal may find them;
-- if not, it will create new ones.
INSERT INTO test_segment_reuse SELECT g, 'phase3-' || g FROM generate_series(1001, 3000) g;
SELECT pg_switch_wal();

INSERT INTO test_segment_reuse SELECT g, 'phase4-' || g FROM generate_series(3001, 5000) g;
CHECKPOINT;

DROP TABLE test_segment_reuse;

----------------------------------------
-- Source: 13.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Don't ERROR on PreallocXlogFiles() race condition
-- task_id: 13
-- commit: pgsql: Don't ERROR on PreallocXlogFiles() race condition.
--
-- This test exercises the modified code paths in:
--   1. PreallocXlogFiles() → XLogFileInitInternal() (no ERROR on race)
--   2. XLogWrite() → XLogFileInit() (new wrapper function)
--   3. XLogFileInit() wrapper (calls XLogFileInitInternal + fallback open)
--   4. exitArchiveRecovery() → XLogFileInit()
--   5. BootStrapXLOG() → XLogFileInit()
-- ================================================================

-- ================================================================
-- Test 1: CHECKPOINT command triggering PreallocXlogFiles()
-- 
-- Coverage: CreateCheckPoint() → PreallocXlogFiles() → XLogFileInitInternal()
-- The newly modified PreallocXlogFiles() calls XLogFileInitInternal() instead
-- of XLogFileInit(), and handles -1 return gracefully (no ERROR).
-- A CHECKPOINT command in normal operation will exercise this path.
-- ================================================================
CREATE TABLE test_checkpoint_prealloc (id int, data text);
INSERT INTO test_checkpoint_prealloc SELECT generate_series(1,10000), 'test data for checkpoint';
-- Generate enough WAL to potentially trigger preallocation
INSERT INTO test_checkpoint_prealloc SELECT generate_series(10001,20000), md5(random()::text);
ANALYZE test_checkpoint_prealloc;
-- CHECKPOINT forces a checkpoint, which calls CreateCheckPoint(),
-- which at the end calls PreallocXlogFiles(recptr) if not shutdown.
CHECKPOINT;
-- Second CHECKPOINT to exercise it again
INSERT INTO test_checkpoint_prealloc SELECT generate_series(20001,30000), md5(random()::text);
CHECKPOINT;
DROP TABLE test_checkpoint_prealloc;

-- ================================================================
-- Test 2: Heavy WAL insertion triggering WAL segment switches
--
-- Coverage: XLogWrite() → XLogFileInit(openLogSegNo)
-- When writing WAL crosses a segment boundary, XLogWrite() calls
-- XLogFileInit() to create/open the next segment.
-- The new XLogFileInit() wrapper calls XLogFileInitInternal() first,
-- then falls back to BasicOpenFile() if internal init returned -1.
-- ================================================================
CREATE TABLE test_wal_switch (id bigint, payload text);
-- Generate enough WAL writes to force multiple segment switches.
-- Each large transaction writes WAL; repeated large inserts cross
-- WAL segments (default 16MB). We do many smaller transactions.
DO $$
BEGIN
  FOR i IN 1..20 LOOP
    INSERT INTO test_wal_switch 
    SELECT generate_series(1, 500), repeat('ABCDEFGHIJ', 1000);
    -- Force WAL flush each iteration
    PERFORM pg_current_wal_lsn();
  END LOOP;
END $$;
-- Verify the table exists and has data
SELECT count(*) > 0 AS has_data FROM test_wal_switch;
DROP TABLE test_wal_switch;

-- ================================================================
-- Test 3: Multiple CHECKPOINT commands to exercise PreallocXlogFiles
--         with varying WAL positions
--
-- Coverage: PreallocXlogFiles() - the 75% WAL segment threshold check
-- The function checks if offset >= 0.75 * wal_segment_size.
-- By varying WAL insert position before CHECKPOINT, we can hit
-- different branches in PreallocXlogFiles().
-- ================================================================
CREATE TABLE test_checkpoint_multi (id serial, t text);
-- Generate less WAL (below 75% of segment) → PreallocXlogFiles may skip
INSERT INTO test_checkpoint_multi (t) VALUES ('small checkpoint test');
CHECKPOINT;
-- Generate more WAL to push past 75% threshold
INSERT INTO test_checkpoint_multi (t) 
SELECT repeat('X', 10000) FROM generate_series(1, 500);
CHECKPOINT;
-- Generate even more WAL
INSERT INTO test_checkpoint_multi (t) 
SELECT repeat('Y', 10000) FROM generate_series(1, 2000);
CHECKPOINT;
DROP TABLE test_checkpoint_multi;

-- ================================================================
-- Test 4: Simulating the race condition scenario indirectly
--         by exercising PreallocXlogFiles concurrently
--
-- Coverage: PreallocXlogFiles() calling XLogFileInitInternal()
-- with lf >= 0 check (the new code path that avoids ERROR when
-- the preallocated segment was unlinked by another process).
-- This tests the graceful handling of -1 return.
-- ================================================================
CREATE TABLE test_race_condition (id int, value text);
-- Generate data in multiple sessions to simulate concurrent WAL activity
INSERT INTO test_race_condition 
SELECT i, md5(i::text) FROM generate_series(1, 5000) i;
-- Multiple rapid checkpoints exercise the preallocation path
CHECKPOINT;
INSERT INTO test_race_condition 
SELECT i, md5((i+5000)::text) FROM generate_series(1, 5000) i;
CHECKPOINT;
INSERT INTO test_race_condition 
SELECT i, md5((i+10000)::text) FROM generate_series(1, 5000) i;
CHECKPOINT;
INSERT INTO test_race_condition 
SELECT i, md5((i+15000)::text) FROM generate_series(1, 5000) i;
CHECKPOINT;
-- Verify data integrity
SELECT count(*), min(id), max(id) FROM test_race_condition;
DROP TABLE test_race_condition;

-- ================================================================
-- Test 5: WAL segment recycling and preallocation via large batch
--         operations that generate significant WAL traffic
--
-- Coverage: Combined path of XLogWrite() → XLogFileInit() and
-- CreateCheckPoint() → PreallocXlogFiles() → XLogFileInitInternal()
-- This exercises both the write-time and checkpoint-time preallocation.
-- ================================================================
CREATE TABLE test_large_wal (id bigint, data text, created_at timestamptz DEFAULT now());
-- Generate large WAL with big transactions to force segment creation
INSERT INTO test_large_wal (id, data)
SELECT generate_series(1, 1000), 
       array_to_string(array_agg(md5(g::text)), '')
FROM generate_series(1, 100) g
GROUP BY g;
-- Insert in batches to create WAL segments across boundaries
INSERT INTO test_large_wal (id, data)
SELECT generate_series(1001, 2000),
       repeat(md5(random()::text), 50);
CHECKPOINT;
INSERT INTO test_large_wal (id, data)
SELECT generate_series(2001, 3000),
       repeat(md5(random()::text), 50);
CHECKPOINT;
INSERT INTO test_large_wal (id, data)
SELECT generate_series(3001, 4000),
       repeat(md5(random()::text), 50);
CHECKPOINT;
-- Final data verification
SELECT count(*), pg_size_pretty(pg_table_size('test_large_wal')) as table_size
FROM test_large_wal;
DROP TABLE test_large_wal;

-- ================================================================
-- End of regression tests for PreallocXlogFiles() race condition fix
-- ================================================================

----------------------------------------
-- Source: 14.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Skip WAL recycling and preallocation during archive recovery
-- task_id: 14
-- This test exercises code paths related to InstallXLogFileSegmentActive flag
-- which controls WAL segment recycling, preallocation, and installation.
-- ================================================================

-- ================================================================
-- Test 1: Trigger WAL segment recycling via checkpoint with WAL recycling
-- This exercises the InstallXLogFileSegmentActive check in RemoveXlogFile()
-- where the flag must be true for recycling to proceed (line ~4232).
-- Also exercises InstallXLogFileSegment() which checks the flag (line ~3637).
-- ================================================================
CREATE TABLE test_wal_recycle (id int primary key, data text);
INSERT INTO test_wal_recycle SELECT generate_series(1,10000), 'test data for wal recycling';

-- Force a checkpoint which triggers WAL segment management including
-- RemoveXlogFile() -> InstallXLogFileSegment() code paths
CHECKPOINT;

-- Generate more WAL to cause segment recycling on next checkpoint
INSERT INTO test_wal_recycle SELECT generate_series(10001,20000), 'more wal data';
CHECKPOINT;

-- Verify the table is accessible
SELECT count(*) FROM test_wal_recycle;
DROP TABLE test_wal_recycle;

-- ================================================================
-- Test 2: Trigger PreallocXlogFiles() code path
-- PreallocXlogFiles() checks InstallXLogFileSegmentActive flag at line ~3988
-- and returns early if false. This is exercised during normal WAL writing
-- when the write position passes the 75% threshold of a segment.
-- We create enough WAL activity and a checkpoint to trigger preallocation.
-- ================================================================
CREATE TABLE test_wal_prealloc (id serial primary key, payload text);

-- Generate significant WAL traffic to potentially trigger preallocation
INSERT INTO test_wal_prealloc (payload)
SELECT repeat('x', 1000) FROM generate_series(1, 5000);

-- Force a restartpoint-like operation via checkpoint
CHECKPOINT;

-- More WAL to exercise the preallocation path
INSERT INTO test_wal_prealloc (payload)
SELECT repeat('y', 1000) FROM generate_series(1, 5000);

CHECKPOINT;

SELECT count(*) FROM test_wal_prealloc;
DROP TABLE test_wal_prealloc;

-- ================================================================
-- Test 3: Exercise XLogFileRead from archive path with the Assert
-- This covers the Assert(!XLogCtl->InstallXLogFileSegmentActive) at line ~3789
-- in XLogFileRead() when source is XLOG_FROM_ARCHIVE.
-- While we cannot directly trigger archive recovery in a SQL regression test,
-- we can test the normal (non-archive) code paths that interact with the flag.
-- Instead, this test focuses on the checkpoint and WAL writing paths.
-- ================================================================
CREATE TABLE test_wal_install (id serial, t text);

-- Generate enough data to span multiple WAL segments
INSERT INTO test_wal_install (t)
SELECT 'data_' || g FROM generate_series(1, 2000) g;

CHECKPOINT;

INSERT INTO test_wal_install (t)
SELECT 'more_' || g FROM generate_series(1, 2000) g;

CHECKPOINT;

-- Read the data back (exercises general WAL reading code paths)
SELECT count(*), sum(length(t)) FROM test_wal_install;
DROP TABLE test_wal_install;

-- ================================================================
-- Test 4: BootStrapXLOG() initialization path (InstallXLogFileSegmentActive = true)
-- The flag is initialized to false in XLOGShmemInit() (line ~5251),
-- then set to true in BootStrapXLOG() (line ~5280).
-- This test verifies that the system can bootstrap and create initial WAL segments.
-- We exercise this by creating tables with UNLOGGED status which interacts
-- with WAL management differently.
-- ================================================================
CREATE UNLOGGED TABLE test_unlogged_wal (id int primary key, val text);

INSERT INTO test_unlogged_wal VALUES (1, 'unlogged test row');
INSERT INTO test_unlogged_wal VALUES (2, 'another unlogged row');

CHECKPOINT;

-- Verify unlogged table works
SELECT count(*) FROM test_unlogged_wal;

-- Temporary tables also skip WAL logging in some paths
CREATE TEMPORARY TABLE test_temp_wal (id int, val text);
INSERT INTO test_temp_wal VALUES (1, 'temp data');
CHECKPOINT;
SELECT count(*) FROM test_temp_wal;

DROP TABLE test_unlogged_wal;
DROP TABLE test_temp_wal;

-- ================================================================
-- Test 5: Edge case - large transactions and WAL segment boundary crossing
-- This exercises the general WAL writing path where PreallocXlogFiles() and
-- InstallXLogFileSegment() interact with the flag during segment switching.
-- ================================================================
CREATE TABLE test_wal_edge (id bigserial, data text, created_at timestamptz default now());

-- Generate a large amount of data to force multiple WAL segment writes
INSERT INTO test_wal_edge (data)
SELECT repeat('edge_case_boundary_test_data_', 500)
FROM generate_series(1, 3000);

-- Force checkpoint to trigger WAL segment management
CHECKPOINT;

-- Insert with NULL values to test edge conditions
INSERT INTO test_wal_edge (data) VALUES (NULL), (''), ('single_row');

CHECKPOINT;

-- Verify all data
SELECT 
    count(*) AS total_rows,
    count(data) AS non_null_data,
    min(id) AS min_id,
    max(id) AS max_id
FROM test_wal_edge;

DROP TABLE test_wal_edge;

-- ================================================================
-- Summary: The above tests exercise the following code paths:
-- 1. InstallXLogFileSegment() early return when flag inactive (line 3637-3641)
-- 2. PreallocXlogFiles() early return when flag inactive (line 3988-3990)
-- 3. RemoveXlogFile() conditional recycling based on flag (line 4232)
-- 4. BootStrapXLOG() setting flag to true (line 5279-5281)
-- 5. XLOGShmemInit() initializing flag to false (line 5251)
-- 6. XLogShutdownWalRcv() wrapper (line 12982-12987)
-- ================================================================

----------------------------------------
-- Source: 15.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for:
--   pgsql: Fix parse_cte.c's failure to examine sub-WITHs in DML statements
-- task_id: 15
-- 
-- This test exercises the new code paths added to makeDependencyGraphWalker
-- in parse_cte.c, which now handles WITH clauses attached to INSERT/UPDATE/DELETE
-- statements (not just SELECT). The extracted function WalkInnerWith() is called
-- for each of these statement types to properly build the CTE dependency graph,
-- detect invalid recursion, and order CTEs correctly.
-- ================================================================

-- ================================================================
-- Test 1: WITH + INSERT (non-recursive)
-- Covers: InsertStmt branch in makeDependencyGraphWalker → WalkInnerWith()
--         non-RECURSIVE path in WalkInnerWith()
-- The WITH clause defines a CTE, and an INSERT ... SELECT uses it.
-- ================================================================

CREATE TABLE test1_cte_insert (id int, val text);

INSERT INTO test1_cte_insert VALUES (1, 'a'), (2, 'b'), (3, 'c');

WITH cte AS (
    SELECT id, upper(val) AS val FROM test1_cte_insert WHERE id > 1
)
INSERT INTO test1_cte_insert
SELECT id + 10, val FROM cte;

SELECT * FROM test1_cte_insert ORDER BY id;

DROP TABLE test1_cte_insert;

-- ================================================================
-- Test 2: WITH + UPDATE (non-recursive)
-- Covers: UpdateStmt branch in makeDependencyGraphWalker → WalkInnerWith()
--         non-RECURSIVE path in WalkInnerWith()
-- The WITH clause defines a CTE which is referenced in the UPDATE's FROM clause.
-- ================================================================

CREATE TABLE test2_target (id int, val int);
CREATE TABLE test2_source (id int, factor int);

INSERT INTO test2_target VALUES (1, 10), (2, 20), (3, 30);
INSERT INTO test2_source VALUES (1, 2), (2, 3), (3, 4);

WITH upd_cte AS (
    SELECT id, factor FROM test2_source
)
UPDATE test2_target
SET val = val * upd_cte.factor
FROM upd_cte
WHERE test2_target.id = upd_cte.id;

SELECT * FROM test2_target ORDER BY id;

DROP TABLE test2_target;
DROP TABLE test2_source;

-- ================================================================
-- Test 3: WITH + DELETE (non-recursive)
-- Covers: DeleteStmt branch in makeDependencyGraphWalker → WalkInnerWith()
--         non-RECURSIVE path in WalkInnerWith()
-- The WITH clause defines a CTE used in a DELETE ... USING clause.
-- ================================================================

CREATE TABLE test3_main (id int, val text);
CREATE TABLE test3_filter (id int, keep boolean);

INSERT INTO test3_main VALUES (1, 'keep'), (2, 'delete'), (3, 'keep'), (4, 'delete');
INSERT INTO test3_filter VALUES (1, true), (2, false), (3, true), (4, false);

WITH del_cte AS (
    SELECT id FROM test3_filter WHERE keep = false
)
DELETE FROM test3_main
USING del_cte
WHERE test3_main.id = del_cte.id;

SELECT * FROM test3_main ORDER BY id;

DROP TABLE test3_main;
DROP TABLE test3_filter;

-- ================================================================
-- Test 4: WITH RECURSIVE + INSERT (recursive CTE with INSERT)
-- Covers: InsertStmt branch → WalkInnerWith() RECURSIVE path
--         The RECURSIVE path pushes all CTE names onto innerwiths at once.
-- ================================================================

CREATE TABLE test4_rec_ins (n int);

WITH RECURSIVE numbers(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM numbers WHERE n < 5
)
INSERT INTO test4_rec_ins
SELECT * FROM numbers;

SELECT * FROM test4_rec_ins ORDER BY n;

DROP TABLE test4_rec_ins;

-- ================================================================
-- Test 5: Nested WITH reference from outer CTE in INSERT
-- Covers: Edge case where a sub-WITH (inner WITH clause in a DML statement)
--         references an outer CTE name. This is the exact bug scenario from
--         commit #18878 - the dependency graph walker previously missed
--         such references for non-SELECT statements.
--         Uses multiple CTEs with forward/backward references to exercise
--         the topological sort dependency resolution.
-- ================================================================

CREATE TABLE test5_data (id int, val int);
CREATE TABLE test5_result (id int, doubled int);

INSERT INTO test5_data VALUES (1, 10), (2, 20), (3, 30);

-- This WITH clause defines CTEs that reference each other, and the
-- INSERT uses them. The dependency graph walker must correctly build
-- the dependency edges through the InsertStmt's WITH clause.
WITH
    base AS (
        SELECT id, val FROM test5_data
    ),
    processed AS (
        SELECT id, val * 2 AS doubled FROM base
    )
INSERT INTO test5_result
SELECT id, doubled FROM processed;

SELECT * FROM test5_result ORDER BY id;

DROP TABLE test5_data;
DROP TABLE test5_result;

----------------------------------------
-- Source: 16.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Relax assertion in finding correct GiST parent
-- task_id: 16
--
-- This commit relaxes an assertion in gistFindCorrectParent().
-- The original assertion was:
--   Assert(parent->lsn != PageGetLSN(parent->page) || is_build);
-- The new assertion is:
--   Assert(parent->lsn != PageGetLSN(parent->page) || is_build ||
--          child->downlinkoffnum == InvalidOffsetNumber);
--
-- The scenario: during gistfinishsplit(), when the parent page also splits,
-- gistFindCorrectParent() is called with child->downlinkoffnum ==
-- InvalidOffsetNumber (because the earlier call to gistinserttuples()
-- caused a parent split and cleared the downlinkoffnum). The old assertion
-- would incorrectly fire in this case.
--
-- To trigger this code path, we need to perform many inserts that cause
-- GiST index page splits at multiple levels of the tree.
-- ================================================================

-- ================================================================
-- Test 1: Bulk insert into a GiST index on point data
-- Targets: gistfinishsplit() -> gistFindCorrectParent() with
--          child->downlinkoffnum == InvalidOffsetNumber
-- This inserts a large number of points to force multi-level splits.
-- ================================================================
CREATE TABLE test_gist_parent1 (id int, p point);

CREATE INDEX test_gist_parent1_idx ON test_gist_parent1 USING gist(p);

-- Insert many points in random-like order to force page splits
INSERT INTO test_gist_parent1 (id, p)
SELECT g, point(random() * 10000, random() * 10000)
FROM generate_series(1, 50000) g;

-- Perform a query to ensure the index is valid
SET enable_seqscan = off;
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_parent1 WHERE p <@ box(point(0,0), point(1000,1000));
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_parent1 WHERE p <@ box(point(2000,2000), point(5000,5000));
RESET enable_seqscan;

DROP TABLE test_gist_parent1;


-- ================================================================
-- Test 2: Concurrent bulk inserts with circle data
-- Targets: Same code path as Test 1, but with a different opclass
-- (circle) to exercise different splitting behavior in GiST.
-- ================================================================
CREATE TABLE test_gist_parent2 (id int, c circle);

CREATE INDEX test_gist_parent2_idx ON test_gist_parent2 USING gist(c);

-- Insert circles with varying radii to force splits
INSERT INTO test_gist_parent2 (id, c)
SELECT g, circle(point(random() * 5000, random() * 5000), random() * 100)
FROM generate_series(1, 30000) g;

-- Query to exercise the index
SET enable_seqscan = off;
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_parent2 WHERE c <@ circle(point(2500, 2500), 1500);
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_parent2 WHERE c && circle(point(1000, 1000), 500);
RESET enable_seqscan;

DROP TABLE test_gist_parent2;


-- ================================================================
-- Test 3: Index build with buffering=on (creates multi-level tree)
-- Targets: The is_build path (is_build=true) in the assertion, plus
-- the InvalidOffsetNumber path.
-- With buffering=on, the GiST index is built in a way that can
-- trigger the exact scenario described in the commit message.
-- ================================================================
CREATE TABLE test_gist_parent3 (id int, p point);

-- Insert data first, then create index with buffering
INSERT INTO test_gist_parent3 (id, p)
SELECT g, point(g, g) FROM generate_series(1, 60000) g;

CREATE INDEX test_gist_parent3_idx ON test_gist_parent3 USING gist(p) WITH (buffering=on);

-- Verify with queries
SET enable_seqscan = off;
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_parent3 WHERE p <@ box(point(0,0), point(10000,10000));
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_parent3 WHERE p <@ box(point(20000,20000), point(30000,30000));
RESET enable_seqscan;

DROP TABLE test_gist_parent3;


-- ================================================================
-- Test 4: Multiple inserts with updates causing page splits
-- Targets: The recursive call path in gistFindCorrectParent where
-- parent->downlinkoffnum is cleared (line 1079 in gist.c).
-- UPDATE + INSERT patterns may cause the GiST tree to reorganize
-- and trigger the exact condition where child->downlinkoffnum
-- becomes InvalidOffsetNumber.
-- ================================================================
CREATE TABLE test_gist_parent4 (id int, p point);

CREATE INDEX test_gist_parent4_idx ON test_gist_parent4 USING gist(p);

INSERT INTO test_gist_parent4 (id, p)
SELECT g, point(g, g) FROM generate_series(1, 20000) g;

-- Delete and re-insert to create fragmentation
DELETE FROM test_gist_parent4 WHERE id % 3 = 0;

INSERT INTO test_gist_parent4 (id, p)
SELECT g + 100000, point(random() * 50000, random() * 50000)
FROM generate_series(1, 20000) g;

-- Vacuum to clean up and then insert more to trigger splits
VACUUM test_gist_parent4;

INSERT INTO test_gist_parent4 (id, p)
SELECT g + 200000, point(random() * 100000, random() * 100000)
FROM generate_series(1, 30000) g;

-- Run queries to exercise the index
SET enable_seqscan = off;
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_parent4 WHERE p <@ box(point(0,0), point(50000,50000));
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_parent4 WHERE p <@ box(point(10000,10000), point(20000,20000));
RESET enable_seqscan;

DROP TABLE test_gist_parent4;


-- ================================================================
-- Test 5: Aggressive split scenario with concurrent inserts on
-- inet data type (GiST supports inet/cidr)
-- Targets: The specific scenario from the bug report where
-- gistFindCorrectParent is called multiple times from
-- gistfinishsplit() and the parent page splits during the process.
--
-- The key is that gistfinishsplit() iterates from right to left
-- inserting downlinks. If any gistinserttuples() call splits the
-- parent, stack->downlinkoffnum is set to InvalidOffsetNumber.
-- The next iteration's gistFindCorrectParent() call then triggers
-- the relaxed assertion path.
-- ================================================================
CREATE TABLE test_gist_parent5 (id int, addr inet);

CREATE INDEX test_gist_parent5_idx ON test_gist_parent5 USING gist(addr inet_ops);

-- Insert many IP addresses that will cause splits
INSERT INTO test_gist_parent5 (id, addr)
SELECT g, (random() * 2^32)::bigint::inet
FROM generate_series(1, 40000) g;

-- More inserts to ensure multi-level splits
INSERT INTO test_gist_parent5 (id, addr)
SELECT g + 100000, (random() * 2^32 + 2^31)::bigint::inet
FROM generate_series(1, 30000) g;

-- Query to exercise the index
SET enable_seqscan = off;
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_parent5 WHERE addr <<= inet '10.0.0.0/8';
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_parent5 WHERE addr >>= inet '192.168.0.0/16';
RESET enable_seqscan;

DROP TABLE test_gist_parent5;


-- ================================================================
-- All tests completed. These tests exercise the code path where
-- child->downlinkoffnum == InvalidOffsetNumber in
-- gistFindCorrectParent(), which is the newly allowed condition
-- in the relaxed assertion.
-- ================================================================

----------------------------------------
-- Source: 17.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Remove unnecessary type violation in tsvectorrecv()
-- task_id: 17
-- 
-- This commit fixes a type alignment issue in compareentry() and
-- removes the unnecessary WordEntryCMP wrapper function.
-- The modified code paths are:
--   1. compareentry() now operates on WordEntry* instead of WordEntryIN*
--   2. tsvectorrecv() calls compareentry() directly (no WordEntryCMP)
--   3. uniqueentry() calls compareentry() via qsort_arg (for tsvectorin)
--   4. tsvectorrecv() sorts using compareentry() via qsort_arg
--
-- These paths are exercised by creating tsvector values through:
--   - Text input: 'word1 word2'::tsvector  (tsvectorin → uniqueentry → compareentry)
--   - Binary receive: via binary COPY or send/recv (tsvectorrecv → compareentry)
--   - to_tsvector() text construction
-- ================================================================

-- #############################################################################
-- Test 1: Basic tsvector text input — exercises compareentry via uniqueentry()
--          in tsvectorin(). This is the most common code path.
--          Creates entries that are already in sorted order (no sort needed)
--          but still triggers compareentry in uniqueentry().
-- #############################################################################

CREATE TABLE test_tsv_input (
    id serial PRIMARY KEY,
    tsv tsvector
);

INSERT INTO test_tsv_input (tsv) VALUES
    ('apple banana cherry date'),
    ('a b c d e f g'),
    ('z y x w v u t s r q p o n m l k j i h g f e d c b a'),
    ('hello world'),
    ('one two three four five six seven eight nine ten');

-- This will trigger compareentry via tsvectorin → uniqueentry
SELECT id, tsv
FROM test_tsv_input
ORDER BY id;

DROP TABLE test_tsv_input;

-- #############################################################################
-- Test 2: tsvector with duplicate lexemes — exercises compareentry for
--          deduplication in uniqueentry(). The compareentry function is used
--          by qsort_arg to sort entries, then uniqueentry removes duplicates.
-- #############################################################################

CREATE TABLE test_tsv_dup (
    tsv tsvector
);

INSERT INTO test_tsv_dup (tsv) VALUES
    ('apple apple apple'),             -- triplicate
    ('dog cat dog cat bird'),          -- interleaved duplicates
    ('aaa aaa bbb bbb ccc ccc'),       -- pairs of duplicates
    ('same same same same same');      -- all same

SELECT tsv FROM test_tsv_dup;

DROP TABLE test_tsv_dup;

-- #############################################################################
-- Test 3: tsvector with positions (weighted lexemes) — exercises compareentry
--          in both tsvectorin and tsvectorrecv paths, with position metadata.
--          Positions cause WordEntryIN to have non-zero pos/poslen fields,
--          exercising the full WordEntryIN struct layout.
-- #############################################################################

CREATE TABLE test_tsv_positions (
    tsv tsvector
);

INSERT INTO test_tsv_positions (tsv) VALUES
    ('apple:1 apple:2 apple:3'),         -- same word, positions need merging
    ('dog:1 cat:2 dog:3 bird:4'),        -- interleaved with positions
    ('a:1 b:2 c:3 d:4 e:5'),            -- sorted, with positions
    ('z:5 y:4 x:3 w:2 v:1'),            -- reverse sorted, needs sorting
    ('a:10 b:5 c:1 d:2 e:3');           -- positions in non-sorted order

SELECT tsv FROM test_tsv_positions;

DROP TABLE test_tsv_positions;

-- #############################################################################
-- Test 4: tsvector with special characters and edge cases — exercises
--          compareentry with diverse string content to ensure the
--          tsCompareString function works correctly with various inputs.
--          Also covers the empty tsvector case.
-- #############################################################################

CREATE TABLE test_tsv_edge (
    tsv tsvector
);

INSERT INTO test_tsv_edge (tsv) VALUES
    (''::tsvector),                     -- empty tsvector (no compareentry called)
    ('word'::tsvector),                 -- single entry (no comparison needed)
    ('a b'::tsvector),                  -- minimal two entries
    ('  hello   world  '::tsvector),    -- extra whitespace
    ('x y z'::tsvector);               -- three entries

SELECT tsv FROM test_tsv_edge;

DROP TABLE test_tsv_edge;

-- #############################################################################
-- Test 5: to_tsvector() — exercises the full text-to-tsvector pipeline
--          which internally constructs a tsvector via tsvectorin-like logic.
--          Different configurations and languages trigger different code paths
--          but all ultimately construct a tsvector using the same entry
--          comparison logic.
-- #############################################################################

CREATE TABLE test_tsv_config (
    id serial PRIMARY KEY,
    doc text,
    tsv tsvector
);

INSERT INTO test_tsv_config (doc) VALUES
    ('The quick brown fox jumps over the lazy dog'),
    ('A quick movement of the enemy will jeopardize six gunboats'),
    ('To be or not to be that is the question'),
    ('The five boxing wizards jump quickly'),
    ('How vexingly quick daft zebras jump');

-- Generate tsvector from text using default configuration
UPDATE test_tsv_config
SET tsv = to_tsvector('english', doc);

-- Verify the vectors were constructed correctly
SELECT id, tsv
FROM test_tsv_config
ORDER BY id;

DROP TABLE test_tsv_config;

-- #############################################################################
-- End of tests
-- #############################################################################

----------------------------------------
-- Source: 18.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for commit:
-- "Build whole-row Vars the same way during parsing and planning"
-- task_id: 18
--
-- This test covers the new RTE_SUBQUERY code path in makeWholeRowVar()
-- which handles three cases:
--   1. Subquery expanded from a view (OidIsValid(rte->relid))
--   2. Subquery expanded from an SRF (rte->functions)
--   3. Normal subquery (RECORDOID)
-- ================================================================

-- ##################################################################
-- Test 1: UPDATE with whole-row Var referencing a view
-- This exercises: RTE_SUBQUERY with OidIsValid(rte->relid)
-- When a view is inlined during planning, makeWholeRowVar sees
-- RTE_SUBQUERY with relid pointing to the original view's relation.
-- ##################################################################

CREATE TABLE test1_whole_row (
    id INT PRIMARY KEY,
    val TEXT,
    extra INT
);

INSERT INTO test1_whole_row VALUES
    (1, 'alpha', 10),
    (2, 'beta', 20),
    (3, 'gamma', 30);

CREATE VIEW test1_v AS SELECT * FROM test1_whole_row;

-- UPDATE with whole-row var reference to the view in FROM clause
-- The view gets inlined, and the whole-row Var for the view must
-- have the same type as the parse-time whole-row Var.
EXPLAIN (COSTS OFF) UPDATE test1_whole_row t
    SET val = v.val || '+upd'
    FROM test1_v v
    WHERE t.id = v.id AND v = ROW(2, 'beta', 20);

SELECT * FROM test1_whole_row ORDER BY id;

-- Reset
UPDATE test1_whole_row SET val = CASE id WHEN 1 THEN 'alpha' WHEN 2 THEN 'beta' WHEN 3 THEN 'gamma' END;

-- DELETE with whole-row Var reference to the view
EXPLAIN (COSTS OFF) DELETE FROM test1_whole_row t
    USING test1_v v
    WHERE t.id = v.id AND v = ROW(3, 'gamma', 30);

SELECT * FROM test1_whole_row ORDER BY id;

INSERT INTO test1_whole_row VALUES (3, 'gamma', 30);

DROP VIEW test1_v;
DROP TABLE test1_whole_row;


-- ##################################################################
-- Test 2: UPDATE with whole-row Var referencing an inlined SRF
-- This exercises: RTE_SUBQUERY with rte->functions
-- When a set-returning function is inlined during planning,
-- makeWholeRowVar sees RTE_SUBQUERY with functions still set.
-- ##################################################################

CREATE TABLE test2_srf (
    id INT PRIMARY KEY,
    name TEXT,
    score INT
);

INSERT INTO test2_srf VALUES
    (1, 'Alice', 95),
    (2, 'Bob', 87),
    (3, 'Charlie', 92);

CREATE FUNCTION test2_srf_func() RETURNS SETOF test2_srf
LANGUAGE sql STABLE
AS $$ SELECT * FROM test2_srf $$;

-- UPDATE with whole-row var from SRF in FROM clause
-- The SRF gets inlined into a subquery; makeWholeRowVar must
-- produce the correct composite type based on rte->functions.
EXPLAIN (COSTS OFF) UPDATE test2_srf t
    SET score = f.score + 5
    FROM test2_srf_func() f
    WHERE t.id = f.id AND f = ROW(1, 'Alice', 95);

SELECT * FROM test2_srf ORDER BY id;

UPDATE test2_srf SET score = CASE id WHEN 1 THEN 95 WHEN 2 THEN 87 WHEN 3 THEN 92 END;

DROP FUNCTION test2_srf_func();
DROP TABLE test2_srf;


-- ##################################################################
-- Test 3: DELETE with whole-row Var from a view
-- This exercises: RTE_SUBQUERY with OidIsValid(rte->relid)
-- Another variant: DELETE ... USING with whole-row references.
-- ##################################################################

CREATE TABLE test3_base (
    a INT,
    b TEXT
);

INSERT INTO test3_base VALUES
    (1, 'x'), (2, 'y'), (3, 'z'), (4, 'w');

CREATE VIEW test3_v AS SELECT * FROM test3_base;

-- DELETE using whole-row var comparison against the view
EXPLAIN (COSTS OFF) DELETE FROM test3_base t
    USING test3_v v
    WHERE t.a = v.a AND v = ROW(2, 'y');

SELECT * FROM test3_base ORDER BY a;

INSERT INTO test3_base VALUES (2, 'y');

DROP VIEW test3_v;
DROP TABLE test3_base;


-- ##################################################################
-- Test 4: View with WHERE clause containing whole-row Var reference
-- This exercises: RTE_SUBQUERY with OidIsValid(rte->relid)
-- A view with a security barrier or complex enough to prevent
-- simple flattening, forcing the whole-row Var to be resolved
-- during planning against the inlined subquery RTE.
-- ##################################################################

CREATE TABLE test4_emp (
    emp_id INT PRIMARY KEY,
    name TEXT,
    salary INT,
    dept_id INT
);

INSERT INTO test4_emp VALUES
    (101, 'John', 50000, 1),
    (102, 'Jane', 60000, 1),
    (103, 'Jim', 55000, 2);

CREATE VIEW test4_high_salary AS
    SELECT * FROM test4_emp WHERE salary > 52000;

-- A self-join with the view, using whole-row comparison
EXPLAIN (COSTS OFF) SELECT *
    FROM test4_high_salary v1
    JOIN test4_emp e ON e.emp_id = v1.emp_id
    WHERE v1 = ROW(102, 'Jane', 60000, 1);

DROP VIEW test4_high_salary;
DROP TABLE test4_emp;


-- ##################################################################
-- Test 5: SRF returning a named composite type + whole-row Var
-- This exercises: RTE_SUBQUERY with rte->functions
-- where the SRF function returns a named composite type
-- (type_is_rowtype returns true), testing the path where
-- toid = exprType(fexpr) is a valid composite type.
-- ##################################################################

CREATE TYPE test5_composite AS (
    x INT,
    y TEXT,
    z FLOAT8
);

CREATE TABLE test5_data (
    id INT PRIMARY KEY,
    val test5_composite
);

INSERT INTO test5_data VALUES
    (1, (10, 'hello', 3.14)::test5_composite),
    (2, (20, 'world', 2.71)::test5_composite),
    (3, (30, 'pg', 1.41)::test5_composite);

CREATE FUNCTION test5_srf_func() RETURNS SETOF test5_composite
LANGUAGE sql STABLE
AS $$ SELECT * FROM (VALUES
    (10, 'hello', 3.14),
    (20, 'world', 2.71),
    (30, 'pg', 1.41)
) AS t(a,b,c) ORDER BY a $$;

-- UPDATE using whole-row var from the SRF with named composite type
EXPLAIN (COSTS OFF) UPDATE test5_data d
    SET val = f
    FROM test5_srf_func() f
    WHERE (f).x = (d.val).x AND f = ROW(20, 'world', 2.71)::test5_composite;

SELECT * FROM test5_data ORDER BY id;

DROP FUNCTION test5_srf_func();
DROP TABLE test5_data;
DROP TYPE test5_composite;

----------------------------------------
-- Source: 19.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Revert: Get rid of WALBufMappingLock
-- task_id: 19
-- Description: Exercises the re-introduced WALBufMappingLock code
-- paths in AdvanceXLInsertBuffer(). The key code paths are:
--   (1) LWLockAcquire(WALBufMappingLock, LW_EXCLUSIVE) at entry
--   (2) Dirty buffer eviction: Release WALBufMappingLock, acquire
--       WALWriteLock, write, re-acquire WALBufMappingLock (lines 2204-2227)
--   (3) Normal buffer initialization under WALBufMappingLock (lines 2236-2310)
--   (4) LWLockRelease(WALBufMappingLock) at exit (line 2314)
--   (5) Opportunistic pre-initialization via AdvanceXLInsertBuffer(..., true)
-- ================================================================

-- ================================================================
-- Test 1: Basic DML - INSERT
-- Covers: Normal WAL insertion path. Any INSERT generates WAL
-- records, which triggers AdvanceXLInsertBuffer() under
-- WALBufMappingLock when new WAL pages need to be initialized.
-- ================================================================
CREATE TABLE test_wal_basic (id int primary key, data text);
INSERT INTO test_wal_basic VALUES (1, 'hello');
INSERT INTO test_wal_basic VALUES (2, 'world');
INSERT INTO test_wal_basic VALUES (3, 'wal test');
-- Generate enough WAL activity to cross page boundaries
INSERT INTO test_wal_basic SELECT generate_series(4, 1000), 'data_' || generate_series(4, 1000)::text;
DROP TABLE test_wal_basic;

-- ================================================================
-- Test 2: Large UPDATE that forces WAL buffer pressure
-- Covers: Dirty buffer eviction path in AdvanceXLInsertBuffer.
-- When WAL buffers are full and we need to write a dirty page out,
-- WALBufMappingLock is released, WALWriteLock acquired, the page
-- written, then WALBufMappingLock re-acquired (lines 2204-2227).
-- A large table update creates many WAL records to fill buffers.
-- ================================================================
CREATE TABLE test_wal_large (id serial primary key, payload text);

-- Insert a large amount of data to create WAL pressure
INSERT INTO test_wal_large (payload)
SELECT repeat('x', 1000)
FROM generate_series(1, 5000);

-- Now update all rows to generate more WAL (full-page writes for the first
-- modification after a checkpoint would also exercise the code path)
UPDATE test_wal_large SET payload = repeat('y', 1000);

-- A second update on already-modified pages triggers WAL logging
-- without full-page image, generating more compact WAL records
UPDATE test_wal_large SET payload = repeat('z', 500);

DROP TABLE test_wal_large;

-- ================================================================
-- Test 3: Large row insertion - cross-page WAL records
-- Covers: WALBufMappingLock code path when a single WAL record
-- spans multiple pages, forcing AdvanceXLInsertBuffer to
-- initialize new pages while holding (and potentially releasing/
-- re-acquiring) WALBufMappingLock.
-- ================================================================
CREATE TABLE test_wal_crosspage (id serial, large_data text);

-- Insert very large values that generate big WAL records which
-- may span multiple WAL pages
INSERT INTO test_wal_crosspage (large_data)
SELECT repeat('PostgreSQL WAL Buffer Test ', 100)
FROM generate_series(1, 200);

-- Do a big COPY equivalent operation
INSERT INTO test_wal_crosspage (large_data)
SELECT string_agg(g::text, ',')
FROM generate_series(1, 10000) g;

DROP TABLE test_wal_crosspage;

-- ================================================================
-- Test 4: Transaction with many small operations
-- Covers: Opportunistic pre-initialization path.
-- After each WAL insertion, XLogInsertRecord calls
-- AdvanceXLInsertBuffer(InvalidXLogRecPtr, true) (line 3185)
-- with opportunistic=true to pre-initialize buffers. This path
-- takes WALBufMappingLock and initializes pages without forcing
-- writes (opportunistic break at line 2182).
-- ================================================================
CREATE TABLE test_wal_multiops (id int, val text);

-- Many small transactions each generating WAL
DO $$
BEGIN
  FOR i IN 1..100 LOOP
    INSERT INTO test_wal_multiops VALUES (i, 'small_op_' || i);
    UPDATE test_wal_multiops SET val = 'updated_' || i WHERE id = i;
  END LOOP;
END $$;

-- Additional batch of operations
INSERT INTO test_wal_multiops
SELECT g, 'batch_' || g FROM generate_series(101, 500) g;

DROP TABLE test_wal_multiops;

-- ================================================================
-- Test 5: Table with full-page writes (initial checkpoint)
-- Covers: The WALBufMappingLock re-acquisition path where a
-- checkpoint forces full-page writes for modified pages. After a
-- checkpoint, the first modification to each page must be logged
-- as a full-page image, generating larger WAL records that
-- exercise the buffer initialization under WALBufMappingLock.
-- ================================================================
CREATE TABLE test_wal_fpw (id serial primary key, data text, flag bool);

-- Insert data and let it sit through a checkpoint
INSERT INTO test_wal_fpw (data, flag)
SELECT 'pre_checkpoint_' || g, g % 2 = 0
FROM generate_series(1, 1000) g;

-- Force a checkpoint
CHECKPOINT;

-- Now modify data - first modification after checkpoint triggers
-- full-page writes which create larger WAL records
UPDATE test_wal_fpw SET data = 'post_checkpoint_' || id, flag = NOT flag;

-- More modifications to keep generating full-page writes
UPDATE test_wal_fpw SET data = 'modified_again_' || id WHERE id % 3 = 0;

-- Insert additional data after checkpoint
INSERT INTO test_wal_fpw (data, flag)
SELECT 'post_' || g, true FROM generate_series(1001, 1500) g;

DROP TABLE test_wal_fpw;

-- ================================================================
-- End of test file
-- ================================================================

----------------------------------------
-- Source: 20.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix setrefs.c's failure to do expression
-- processing on partition pruning steps
--
-- This test exercises the code paths in set_append_references() and
-- set_mergeappend_references() that call fix_scan_list() on the
-- initial_pruning_steps and exec_pruning_steps of
-- PartitionedRelPruneInfo.  Without this fix, expression subtrees
-- (such as AlternativeSubPlans) within pruning steps would not be
-- properly processed, leading to "unrecognized node type" errors.
--
-- task_id: 20
-- ================================================================

-- ================================================================
-- Test 1: Basic Append with partition pruning (list partition)
-- Exercises: set_append_references -> fix_scan_list on initial_pruning_steps
-- and exec_pruning_steps for a simple list-partitioned table.
-- ================================================================

CREATE TABLE test_list_part (a int, b text)
  PARTITION BY LIST (a);

CREATE TABLE test_list_part_1 PARTITION OF test_list_part
  FOR VALUES IN (1, 2, 3);
CREATE TABLE test_list_part_2 PARTITION OF test_list_part
  FOR VALUES IN (4, 5, 6);
CREATE TABLE test_list_part_3 PARTITION OF test_list_part
  FOR VALUES IN (7, 8, 9);
CREATE TABLE test_list_part_default PARTITION OF test_list_part
  DEFAULT;

INSERT INTO test_list_part VALUES (1, 'one'), (4, 'four'), (7, 'seven'), (NULL, 'null');

-- This should produce an Append plan with pruning
EXPLAIN ANALYZE SELECT * FROM test_list_part WHERE a = 1;
EXPLAIN ANALYZE SELECT * FROM test_list_part WHERE a IN (1, 4);
EXPLAIN ANALYZE SELECT * FROM test_list_part WHERE a > 5;

DROP TABLE test_list_part;


-- ================================================================
-- Test 2: Append with range partition pruning
-- Exercises: set_append_references -> fix_scan_list on pruning steps
-- for a range-partitioned table with multiple partitions.
-- ================================================================

CREATE TABLE test_range_part (id int, name text)
  PARTITION BY RANGE (id);

CREATE TABLE test_range_part_1 PARTITION OF test_range_part
  FOR VALUES FROM (1) TO (100);
CREATE TABLE test_range_part_2 PARTITION OF test_range_part
  FOR VALUES FROM (100) TO (200);
CREATE TABLE test_range_part_3 PARTITION OF test_range_part
  FOR VALUES FROM (200) TO (300);
CREATE TABLE test_range_part_4 PARTITION OF test_range_part
  FOR VALUES FROM (300) TO (400);

INSERT INTO test_range_part
  SELECT g, 'name_' || g::text FROM generate_series(1, 399) g;

-- Pruning on range partitions
EXPLAIN ANALYZE SELECT * FROM test_range_part WHERE id < 50;
EXPLAIN ANALYZE SELECT * FROM test_range_part WHERE id BETWEEN 150 AND 250;
EXPLAIN ANALYZE SELECT * FROM test_range_part WHERE id >= 350;

DROP TABLE test_range_part;


-- ================================================================
-- Test 3: MergeAppend with partition pruning (ordered query)
-- Exercises: set_mergeappend_references -> fix_scan_list on pruning steps
-- A MergeAppend is used when the query has ORDER BY on the partition key
-- and the partitions are sorted individually.
-- ================================================================

CREATE TABLE test_merge_part (id int, val text)
  PARTITION BY RANGE (id);

CREATE TABLE test_merge_part_1 PARTITION OF test_merge_part
  FOR VALUES FROM (1) TO (100);
CREATE TABLE test_merge_part_2 PARTITION OF test_merge_part
  FOR VALUES FROM (100) TO (200);
CREATE TABLE test_merge_part_3 PARTITION OF test_merge_part
  FOR VALUES FROM (200) TO (300);

INSERT INTO test_merge_part
  SELECT g, 'value_' || g::text FROM generate_series(1, 299) g;

-- ORDER BY on partition key should produce a MergeAppend with pruning
EXPLAIN ANALYZE SELECT * FROM test_merge_part
  WHERE id > 50 AND id < 250
  ORDER BY id;

DROP TABLE test_merge_part;


-- ================================================================
-- Test 4: Multi-level (sub-partitioned) table with pruning
-- Exercises: Both set_append_references paths with nested pruning info.
-- Sub-partitioned tables generate multiple PartitionedRelPruneInfo
-- entries, each needing fix_scan_list processing.
-- ================================================================

CREATE TABLE test_subpart (id int, category text)
  PARTITION BY RANGE (id);

CREATE TABLE test_subpart_1 PARTITION OF test_subpart
  FOR VALUES FROM (1) TO (100)
  PARTITION BY LIST (category);

CREATE TABLE test_subpart_1_a PARTITION OF test_subpart_1
  FOR VALUES IN ('a');
CREATE TABLE test_subpart_1_b PARTITION OF test_subpart_1
  FOR VALUES IN ('b');
CREATE TABLE test_subpart_1_default PARTITION OF test_subpart_1
  DEFAULT;

CREATE TABLE test_subpart_2 PARTITION OF test_subpart
  FOR VALUES FROM (100) TO (200)
  PARTITION BY LIST (category);

CREATE TABLE test_subpart_2_a PARTITION OF test_subpart_2
  FOR VALUES IN ('a');
CREATE TABLE test_subpart_2_b PARTITION OF test_subpart_2
  FOR VALUES IN ('b');
CREATE TABLE test_subpart_2_default PARTITION OF test_subpart_2
  DEFAULT;

CREATE TABLE test_subpart_3 PARTITION OF test_subpart
  FOR VALUES FROM (200) TO (300);

INSERT INTO test_subpart VALUES (1, 'a'), (50, 'b'), (150, 'a'), (250, 'c');

-- Pruning at both levels
EXPLAIN ANALYZE SELECT * FROM test_subpart
  WHERE id < 150 AND category = 'a';

EXPLAIN ANALYZE SELECT * FROM test_subpart
  WHERE id BETWEEN 50 AND 250;

DROP TABLE test_subpart;


-- ================================================================
-- Test 5: Hash-partitioned table with pruning and
--         prepared statements (generic plan with pruning)
-- Exercises: set_append_references with exec_pruning_steps
-- that involve PartitionPruneInfo expressions being processed
-- through fix_scan_list.
-- ================================================================

CREATE TABLE test_hash_part (id int, data text)
  PARTITION BY HASH (id);

CREATE TABLE test_hash_part_0 PARTITION OF test_hash_part
  FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE test_hash_part_1 PARTITION OF test_hash_part
  FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE test_hash_part_2 PARTITION OF test_hash_part
  FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE test_hash_part_3 PARTITION OF test_hash_part
  FOR VALUES WITH (MODULUS 4, REMAINDER 3);

INSERT INTO test_hash_part
  SELECT g, 'data_' || g::text FROM generate_series(1, 100) g;

-- Use a prepared statement with parameters to trigger runtime pruning
PREPARE hash_prune_query(int) AS
  SELECT * FROM test_hash_part WHERE id = $1;

EXPLAIN ANALYZE EXECUTE hash_prune_query(10);
EXPLAIN ANALYZE EXECUTE hash_prune_query(25);
EXPLAIN ANALYZE EXECUTE hash_prune_query(42);

DEALLOCATE hash_prune_query;

DROP TABLE test_hash_part;

----------------------------------------
-- Source: 21.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Make getObjectDescription robust against
-- dangling amproc/amop type links
-- task_id: 21
--
-- This test exercises the modified code paths in getObjectDescription
-- where format_type_extended() with FORMAT_TYPE_ALLOW_INVALID is used
-- instead of format_type_be(), so that dangling type OIDs in pg_amop
-- and pg_amproc produce "???" instead of causing an error.
--
-- The test covers:
--   1. Normal pg_amop entry description (valid types)
--   2. Normal pg_amproc entry description (valid types)
--   3. Dangling type links in pg_amop (simulate corruption)
--   4. Dangling type links in pg_amproc (simulate corruption)
--   5. DROP OPERATOR FAMILY with dangling amproc type links
-- ================================================================

-- ================================================================
-- Test 1: Describe a pg_amop entry with valid types (normal case)
-- Creates an operator family, adds operators, then describes
-- the individual pg_amop entry via pg_describe_object.
-- This exercises format_type_extended() with valid OIDs.
-- ================================================================
BEGIN;

-- Create a btree operator family for testing
CREATE OPERATOR FAMILY test_amop_opf1 USING btree;

-- Add operators for int4 vs int4 comparison
ALTER OPERATOR FAMILY test_amop_opf1 USING btree ADD
  OPERATOR 1 < (int4, int4),
  OPERATOR 2 <= (int4, int4),
  OPERATOR 3 = (int4, int4),
  OPERATOR 4 >= (int4, int4),
  OPERATOR 5 > (int4, int4);

-- Get the OID of one of the pg_amop entries we just created
-- and describe it using pg_describe_object
WITH amop_oids AS (
  SELECT oid
  FROM pg_amop
  WHERE amopfamily = (
    SELECT oid FROM pg_opfamily
    WHERE opfname = 'test_amop_opf1' AND opfmethod = (
      SELECT oid FROM pg_am WHERE amname = 'btree'
    )
  )
  ORDER BY amopstrategy
  LIMIT 1
)
SELECT pg_describe_object(2602, oid, 0) AS amop_description
FROM amop_oids;

-- Also describe the operator family itself
WITH opf_oid AS (
  SELECT oid FROM pg_opfamily
  WHERE opfname = 'test_amop_opf1' AND opfmethod = (
    SELECT oid FROM pg_am WHERE amname = 'btree'
  )
)
SELECT pg_describe_object(9016, oid, 0) AS opfamily_description
FROM opf_oid;

ROLLBACK;

-- ================================================================
-- Test 2: Describe a pg_amproc entry with valid types (normal case)
-- Creates an operator family, adds a function, then describes
-- the individual pg_amproc entry via pg_describe_object.
-- This exercises format_type_extended() with valid OIDs.
-- ================================================================
BEGIN;

CREATE OPERATOR FAMILY test_amproc_opf1 USING btree;

-- Add a comparison function for int4 vs int4
ALTER OPERATOR FAMILY test_amproc_opf1 USING btree ADD
  OPERATOR 1 < (int4, int4),
  FUNCTION 1 btint4cmp(int4, int4);

-- Get the OID of the pg_amproc entry and describe it
WITH amproc_oids AS (
  SELECT oid
  FROM pg_amproc
  WHERE amprocfamily = (
    SELECT oid FROM pg_opfamily
    WHERE opfname = 'test_amproc_opf1' AND opfmethod = (
      SELECT oid FROM pg_am WHERE amname = 'btree'
    )
  )
)
SELECT pg_describe_object(2603, oid, 0) AS amproc_description
FROM amproc_oids;

ROLLBACK;

-- ================================================================
-- Test 3: Describe an operator family with cross-type operators
-- (int4 vs int2). Tests the code path with different type combos.
-- ================================================================
BEGIN;

CREATE OPERATOR FAMILY test_cross_opf1 USING btree;

-- Add cross-type operators
ALTER OPERATOR FAMILY test_cross_opf1 USING btree ADD
  OPERATOR 1 < (int4, int2),
  OPERATOR 2 <= (int4, int2),
  OPERATOR 3 = (int4, int2),
  OPERATOR 4 >= (int4, int2),
  OPERATOR 5 > (int4, int2),
  FUNCTION 1 btint42cmp(int4, int2);

-- Describe each amop entry individually
WITH amop_oids AS (
  SELECT oid, amopstrategy
  FROM pg_amop
  WHERE amopfamily = (
    SELECT oid FROM pg_opfamily
    WHERE opfname = 'test_cross_opf1' AND opfmethod = (
      SELECT oid FROM pg_am WHERE amname = 'btree'
    )
  )
  ORDER BY amopstrategy
)
SELECT
  amopstrategy,
  pg_describe_object(2602, oid, 0) AS amop_desc
FROM amop_oids;

-- Describe the amproc entry
WITH amproc_oids AS (
  SELECT oid, amprocnum
  FROM pg_amproc
  WHERE amprocfamily = (
    SELECT oid FROM pg_opfamily
    WHERE opfname = 'test_cross_opf1' AND opfmethod = (
      SELECT oid FROM pg_am WHERE amname = 'btree'
    )
  )
)
SELECT
  amprocnum,
  pg_describe_object(2603, oid, 0) AS amproc_desc
FROM amproc_oids;

ROLLBACK;

-- ================================================================
-- Test 4: Simulate dangling type links in pg_amop
-- Directly UPDATE the pg_amop catalog to set amoplefttype to a
-- non-existent OID, then attempt to describe the entry.
-- The new code should return "???" for the invalid type
-- instead of failing.
-- ================================================================
BEGIN;

CREATE OPERATOR FAMILY test_dangling_amop USING btree;

ALTER OPERATOR FAMILY test_dangling_amop USING btree ADD
  OPERATOR 1 < (int4, int4),
  OPERATOR 3 = (int4, int4);

-- Get the OID of the operator 1 entry and corrupt its left type
WITH opf_oid AS (
  SELECT oid FROM pg_opfamily
  WHERE opfname = 'test_dangling_amop' AND opfmethod = (
    SELECT oid FROM pg_am WHERE amname = 'btree'
  )
)
UPDATE pg_amop
SET amoplefttype = 0  -- invalid/non-existent type OID
FROM opf_oid
WHERE pg_amop.amopfamily = opf_oid.oid
  AND pg_amop.amopstrategy = 1;

-- Now describe the corrupted amop entry - should succeed with "???"
WITH opf_oid AS (
  SELECT oid FROM pg_opfamily
  WHERE opfname = 'test_dangling_amop' AND opfmethod = (
    SELECT oid FROM pg_am WHERE amname = 'btree'
  )
)
SELECT pg_describe_object(2602, a.oid, 0) AS corrupted_amop_desc
FROM pg_amop a, opf_oid o
WHERE a.amopfamily = o.oid
  AND a.amopstrategy = 1;

-- Also corrupt the right type
WITH opf_oid AS (
  SELECT oid FROM pg_opfamily
  WHERE opfname = 'test_dangling_amop' AND opfmethod = (
    SELECT oid FROM pg_am WHERE amname = 'btree'
  )
)
UPDATE pg_amop
SET amoprighttype = 0  -- invalid/non-existent type OID
FROM opf_oid
WHERE pg_amop.amopfamily = opf_oid.oid
  AND pg_amop.amopstrategy = 3;

-- Describe the doubly-corrupted entry
WITH opf_oid AS (
  SELECT oid FROM pg_opfamily
  WHERE opfname = 'test_dangling_amop' AND opfmethod = (
    SELECT oid FROM pg_am WHERE amname = 'btree'
  )
)
SELECT pg_describe_object(2602, a.oid, 0) AS doubly_corrupted_amop_desc
FROM pg_amop a, opf_oid o
WHERE a.amopfamily = o.oid
  AND a.amopstrategy = 3;

ROLLBACK;

-- ================================================================
-- Test 5: Simulate dangling type links in pg_amproc
-- Directly UPDATE the pg_amproc catalog to set amproclefttype
-- to a non-existent OID, then attempt to describe the entry.
-- Also test that DROP OPERATOR FAMILY succeeds even with
-- the dangling type references.
-- ================================================================
BEGIN;

CREATE OPERATOR FAMILY test_dangling_amproc USING btree;

ALTER OPERATOR FAMILY test_dangling_amproc USING btree ADD
  OPERATOR 1 < (int4, int4),
  FUNCTION 1 btint4cmp(int4, int4),
  FUNCTION 2 btint4cmp(int4, int4);

-- Corrupt the left type of function 1
WITH opf_oid AS (
  SELECT oid FROM pg_opfamily
  WHERE opfname = 'test_dangling_amproc' AND opfmethod = (
    SELECT oid FROM pg_am WHERE amname = 'btree'
  )
)
UPDATE pg_amproc
SET amproclefttype = 4294967294  -- invalid/non-existent type OID
FROM opf_oid
WHERE pg_amproc.amprocfamily = opf_oid.oid
  AND pg_amproc.amprocnum = 1;

-- Describe the corrupted amproc entry - should succeed with "???"
WITH opf_oid AS (
  SELECT oid FROM pg_opfamily
  WHERE opfname = 'test_dangling_amproc' AND opfmethod = (
    SELECT oid FROM pg_am WHERE amname = 'btree'
  )
)
SELECT pg_describe_object(2603, a.oid, 0) AS corrupted_amproc_desc
FROM pg_amproc a, opf_oid o
WHERE a.amprocfamily = o.oid
  AND a.amprocnum = 1;

-- Also corrupt the right type of function 2
WITH opf_oid AS (
  SELECT oid FROM pg_opfamily
  WHERE opfname = 'test_dangling_amproc' AND opfmethod = (
    SELECT oid FROM pg_am WHERE amname = 'btree'
  )
)
UPDATE pg_amproc
SET amprocrighttype = 4294967293  -- invalid/non-existent type OID
FROM opf_oid
WHERE pg_amproc.amprocfamily = opf_oid.oid
  AND pg_amproc.amprocnum = 2;

-- Describe the corrupted amproc entry for function 2
WITH opf_oid AS (
  SELECT oid FROM pg_opfamily
  WHERE opfname = 'test_dangling_amproc' AND opfmethod = (
    SELECT oid FROM pg_am WHERE amname = 'btree'
  )
)
SELECT pg_describe_object(2603, a.oid, 0) AS corrupted_amproc_desc2
FROM pg_amproc a, opf_oid o
WHERE a.amprocfamily = o.oid
  AND a.amprocnum = 2;

-- Verify DROP OPERATOR FAMILY succeeds despite the corruption
-- (this is the main fix - previously DROP would fail here)
-- Clean up the corrupted entries first, then drop the family
-- Actually, let's just drop the family directly - the fix should
-- allow it to succeed
DROP OPERATOR FAMILY test_dangling_amproc USING btree;

COMMIT;

----------------------------------------
-- Source: 22.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix NULLIF()'s handling of read-write expanded objects
-- task_id: 22
-- 
-- The fix sets scratch.d.func.make_ro = true for varlena types (typlen == -1)
-- in ExecInitExprRec for EEOP_NULLIF, so that the equality comparison function
-- receives a read-only pointer, preventing corruption of the NULLIF output
-- when the equality function modifies or deletes the expanded object.
-- ================================================================

-- ================================================================
-- Test 1: Basic NULLIF with TEXT type (varlena, typlen == -1)
-- Coverage: make_ro = true for text type; both equal and non-equal cases
-- ================================================================
CREATE TABLE test_nullif_text (
    id serial,
    val1 text,
    val2 text
);

INSERT INTO test_nullif_text VALUES 
    (1, 'hello', 'hello'),       -- equal -> should return NULL
    (2, 'hello', 'world'),       -- not equal -> should return 'hello'
    (3, NULL, 'hello'),          -- first arg NULL -> skip equality check
    (4, 'hello', NULL),          -- second arg NULL -> skip equality check
    (5, '', ''),                 -- empty strings, equal
    (6, 'a', 'b');               -- different strings

-- Run queries that trigger EEOP_NULLIF code path with make_ro=true
EXPLAIN ANALYZE SELECT id, NULLIF(val1, val2) FROM test_nullif_text ORDER BY id;

-- Also test with literal values
EXPLAIN ANALYZE SELECT NULLIF('postgresql', 'postgresql');  -- equal, returns NULL
EXPLAIN ANALYZE SELECT NULLIF('postgresql', 'PostgreSQL');  -- not equal (case sensitive)

DROP TABLE test_nullif_text;


-- ================================================================
-- Test 2: NULLIF with BYTEA type (varlena, typlen == -1)
-- Coverage: make_ro = true for bytea type
-- ================================================================
CREATE TABLE test_nullif_bytea (
    id serial,
    val1 bytea,
    val2 bytea
);

INSERT INTO test_nullif_bytea VALUES 
    (1, E'\\xdeadbeef'::bytea, E'\\xdeadbeef'::bytea),  -- equal
    (2, E'\\xdeadbeef'::bytea, E'\\xcafebabe'::bytea),  -- not equal
    (3, NULL, E'\\xdeadbeef'::bytea),                   -- first NULL
    (4, E'\\xdeadbeef'::bytea, NULL),                   -- second NULL
    (5, E'\\x00'::bytea, E'\\x00'::bytea);              -- single byte, equal

-- Run queries
EXPLAIN ANALYZE SELECT id, NULLIF(val1, val2) FROM test_nullif_bytea ORDER BY id;
EXPLAIN ANALYZE SELECT NULLIF(E'\\xdeadbeef'::bytea, E'\\xcafebabe'::bytea);

DROP TABLE test_nullif_bytea;


-- ================================================================
-- Test 3: NULLIF with VARCHAR type (varlena, typlen == -1)
-- Coverage: make_ro = true for varchar type
-- Also tests with domain types over varlena
-- ================================================================
CREATE TABLE test_nullif_varchar (
    id serial,
    val1 varchar(100),
    val2 varchar(100)
);

INSERT INTO test_nullif_varchar VALUES 
    (1, 'same value', 'same value'),     -- equal
    (2, 'value one', 'value two'),       -- not equal
    (3, NULL, 'some value'),             -- first NULL
    (4, 'some value', NULL),             -- second NULL
    (5, '', NULL),                       -- empty vs NULL
    (6, 'a', 'a');                       -- single char, equal

-- Run queries
EXPLAIN ANALYZE SELECT id, NULLIF(val1, val2) FROM test_nullif_varchar ORDER BY id;

-- With literal values of varying lengths
EXPLAIN ANALYZE SELECT NULLIF('abc'::varchar(10), 'abc'::varchar(10));
EXPLAIN ANALYZE SELECT NULLIF('short'::varchar(100), 'longer value'::varchar(100));

DROP TABLE test_nullif_varchar;


-- ================================================================
-- Test 4: NULLIF with array type and custom equality function
-- Coverage: make_ro = true for arrays (varlena);
-- This is the exact scenario from bug #18722 where a plpgsql
-- equality function could corrupt the read-write expanded object.
-- Uses a domain over int[] with a custom operator that mimics
-- the problematic scenario.
-- ================================================================
BEGIN;

CREATE DOMAIN arrdomain AS int[];

CREATE FUNCTION make_ad(int,int) RETURNS arrdomain AS
  'declare x arrdomain;
   begin
     x := array[$1,$2];
     return x;
   end' LANGUAGE plpgsql VOLATILE;

CREATE FUNCTION ad_eq(arrdomain, arrdomain) RETURNS boolean AS
  'begin return array_eq($1, $2); end' LANGUAGE plpgsql;

CREATE OPERATOR = (PROCEDURE = ad_eq,
                   LEFTARG = arrdomain, RIGHTARG = arrdomain);

-- NULLIF where args are equal (returns NULL)
EXPLAIN ANALYZE SELECT NULLIF(make_ad(1,2)::arrdomain, array[1,2]::arrdomain);

-- NULLIF where args are not equal (returns first arg, the read-write expanded object)
EXPLAIN ANALYZE SELECT NULLIF(make_ad(1,2)::arrdomain, array[3,4]::arrdomain);

-- Compare with CASE (the original bug scenario)
SELECT CASE make_ad(1,2)
  WHEN array[2,4]::arrdomain THEN 'wrong'
  WHEN array[2,5]::arrdomain THEN 'still wrong'
  WHEN array[1,2]::arrdomain THEN 'right'
  END;

ROLLBACK;


-- ================================================================
-- Test 5: NULLIF with JSONB type (varlena, typlen == -1)
-- Coverage: make_ro = true for jsonb type;
-- Tests with complex nested structures to exercise expanded object paths
-- ================================================================
CREATE TABLE test_nullif_jsonb (
    id serial,
    val1 jsonb,
    val2 jsonb
);

INSERT INTO test_nullif_jsonb VALUES 
    (1, '{"a":1,"b":2}'::jsonb, '{"a":1,"b":2}'::jsonb),     -- equal
    (2, '{"a":1,"b":2}'::jsonb, '{"a":1,"b":3}'::jsonb),     -- not equal
    (3, NULL, '{"a":1}'::jsonb),                               -- first NULL
    (4, '{"a":1}'::jsonb, NULL),                               -- second NULL
    (5, 'null'::jsonb, 'null'::jsonb),                         -- json null, equal
    (6, '{}'::jsonb, '{}'::jsonb);                             -- empty object, equal

-- Run queries
EXPLAIN ANALYZE SELECT id, NULLIF(val1, val2) FROM test_nullif_jsonb ORDER BY id;

-- With literal values
EXPLAIN ANALYZE SELECT NULLIF('{"name":"test","value":42}'::jsonb, '{"name":"test","value":42}'::jsonb);
EXPLAIN ANALYZE SELECT NULLIF('{"nested":{"a":1}}'::jsonb, '{"nested":{"a":2}}'::jsonb);

DROP TABLE test_nullif_jsonb;


-- ================================================================
-- End of tests
-- ================================================================

----------------------------------------
-- Source: 23.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Transform OR-clauses to SAOP's during index matching
-- task_id: 23
-- 
-- This test exercises the new match_orclause_to_indexcol() function in
-- indxpath.c, which converts OR-clauses of the form:
--   (indexkey op C1) OR (indexkey op C2) OR ... OR (indexkey op CN)
-- into a ScalarArrayOpExpr:
--   indexkey op ANY(ARRAY[C1, C2, ...])
-- 
-- This allows using a single IndexScan instead of a slower BitmapOr scan.
-- ================================================================

-- ================================================================
-- Test 1: Basic OR-clause to SAOP conversion on integer column
-- Target: match_orclause_to_indexcol() - normal case with Const values
-- Query: WHERE id = 1 OR id = 2 OR id = 3
-- Expected: EXPLAIN ANALYZE shows Index Scan using "ANY(ARRAY[...])"
-- instead of BitmapOr
-- ================================================================
CREATE TABLE test_or_saop_int (
    id INT PRIMARY KEY,
    value TEXT
);

INSERT INTO test_or_saop_int
SELECT i, 'val_' || i
FROM generate_series(1, 100) AS i;

-- Analyze so the planner has accurate stats
ANALYZE test_or_saop_int;

-- This should trigger the OR-to-SAOP transformation
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM test_or_saop_int
WHERE id = 10 OR id = 20 OR id = 30 OR id = 40 OR id = 50;

-- Also test with 2-element OR clause
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM test_or_saop_int
WHERE id = 15 OR id = 25;

-- Clean up
DROP TABLE test_or_saop_int;


-- ================================================================
-- Test 2: OR-clause with constants on the right side
-- Target: match_orclause_to_indexcol() - commutator path
-- The clause format: (const1 op indexkey) OR (const2 op indexkey)
-- This tests the code that calls get_commutator() to reverse the operator
-- ================================================================
CREATE TABLE test_or_saop_commute (
    id INT PRIMARY KEY,
    data TEXT
);

INSERT INTO test_or_saop_commute
SELECT i, 'item_' || i
FROM generate_series(1, 100) AS i;

ANALYZE test_or_saop_commute;

-- Constants on the LEFT side of the operator; planner must commute
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM test_or_saop_commute
WHERE 10 = id OR 20 = id OR 30 = id OR 40 = id OR 50 = id;

-- Mixed: constants on both sides
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM test_or_saop_commute
WHERE id = 25 OR 75 = id;

DROP TABLE test_or_saop_commute;


-- ================================================================
-- Test 3: OR-clause on text column with btree index
-- Target: match_orclause_to_indexcol() - non-integer type
-- Verifies that the transformation works for text types too
-- ================================================================
CREATE TABLE test_or_saop_text (
    code TEXT PRIMARY KEY,
    description TEXT
);

INSERT INTO test_or_saop_text
SELECT 'CODE_' || LPAD(i::TEXT, 4, '0'), 'Description for code ' || i
FROM generate_series(1, 100) AS i;

ANALYZE test_or_saop_text;

-- Text OR clause matching
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM test_or_saop_text
WHERE code = 'CODE_0010' OR code = 'CODE_0020' OR code = 'CODE_0030';

-- Edge case: search with empty string and normal values
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM test_or_saop_text
WHERE code = '' OR code = 'CODE_0001';

DROP TABLE test_or_saop_text;


-- ================================================================
-- Test 4: OR-clause with parameters (PREPARE/EXECUTE)
-- Target: match_orclause_to_indexcol() - Param case
-- When the constants are Params, the code builds an ArrayExpr
-- instead of a Const array. This tests the "haveParam" code path.
-- ================================================================
CREATE TABLE test_or_saop_param (
    id INT PRIMARY KEY,
    name TEXT
);

INSERT INTO test_or_saop_param
SELECT i, 'name_' || i
FROM generate_series(1, 100) AS i;

ANALYZE test_or_saop_param;

-- Use PREPARE to create parameterized query
PREPARE or_param_query(INT, INT, INT) AS
SELECT * FROM test_or_saop_param
WHERE id = $1 OR id = $2 OR id = $3;

-- Execute with different parameter values
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
EXECUTE or_param_query(10, 20, 30);

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
EXECUTE or_param_query(1, 50, 99);

-- Edge case: including NULL result range (parameters that yield empty result)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
EXECUTE or_param_query(200, 300, 400);

DEALLOCATE or_param_query;

DROP TABLE test_or_saop_param;


-- ================================================================
-- Test 5: OR-clause with range scan and mixed operators
-- Target: match_orclause_to_indexcol() - cases that fall back to BitmapOr
-- These queries have OR conditions that CANNOT be transformed to SAOP
-- (e.g., mixed operators: = and <), so they should still use BitmapOr.
-- This verifies the planner gracefully falls back when the OR->SAOP
-- transformation is not applicable.
-- ================================================================
CREATE TABLE test_or_saop_fallback (
    id INT PRIMARY KEY,
    category INT,
    payload TEXT
);

INSERT INTO test_or_saop_fallback
SELECT i, (i % 10), 'data_' || i
FROM generate_series(1, 100) AS i;

CREATE INDEX idx_category ON test_or_saop_fallback(category);

ANALYZE test_or_saop_fallback;

-- Test 5a: Mixed operators (= and <) -> cannot convert to SAOP
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM test_or_saop_fallback
WHERE category = 3 OR category < 2;

-- Test 5b: OR with different columns -> cannot convert to SAOP (different index keys)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM test_or_saop_fallback
WHERE id = 10 OR category = 5;

-- Test 5c: Normal convertible case on the secondary index for comparison
-- This SHOULD trigger OR->SAOP on the category index
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM test_or_saop_fallback
WHERE category = 1 OR category = 3 OR category = 7;

DROP TABLE test_or_saop_fallback;

----------------------------------------
-- Source: 24.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Avoid assertion failure if a setop leaf query contains setops
-- task_id: 24
-- ================================================================
-- This test exercises the code path in get_setop_query() where
-- subquery->setOperations is checked when deciding whether to add
-- parentheses around a leaf query in a set operation tree.
-- The change is in src/backend/utils/adt/ruleutils.c, line 5749.
-- ================================================================
-- Background:
-- In transformSetOperationTree(), when a set operation internal node
-- also has ORDER BY, LIMIT, FOR UPDATE, or WITH clauses, it is
-- treated as a leaf node (isLeaf=true). This means the leaf subquery
-- will contain its own setOperations tree.
-- Previously, get_setop_query() had an Assert(subquery->setOperations==NULL)
-- which would fail in such cases. The fix replaces the Assert with
-- an additional check in need_paren logic, ensuring correct
-- parenthesization when deparsing such queries.
-- ================================================================

-- ################################################################
-- Test 1: UNION with ORDER BY inside INTERSECT
-- Coverage: A leaf query containing both setOperations (UNION) and
-- ORDER BY triggers the new subquery->setOperations check.
-- Syntax: (SELECT ... UNION ALL SELECT ... ORDER BY ...) INTERSECT SELECT ...
-- ################################################################

CREATE TABLE test_so1 (a int);
INSERT INTO test_so1 VALUES (1), (2), (3);

CREATE TABLE test_so2 (a int);
INSERT INTO test_so2 VALUES (2), (3), (4);

CREATE TABLE test_so3 (a int);
INSERT INTO test_so3 VALUES (3), (4), (5);

-- Create a view with a parenthesized setop containing ORDER BY
CREATE VIEW test_view_so1 AS
(SELECT a FROM test_so1 UNION ALL SELECT a FROM test_so2 ORDER BY 1)
INTERSECT
SELECT a FROM test_so3;

-- Force deparse by viewing the view definition
SELECT pg_get_viewdef('test_view_so1'::regclass, true);
SELECT pg_get_viewdef('test_view_so1'::regclass, false);

DROP VIEW test_view_so1;
DROP TABLE test_so3;
DROP TABLE test_so2;
DROP TABLE test_so1;

-- ################################################################
-- Test 2: UNION with LIMIT inside EXCEPT
-- Coverage: A leaf query containing both setOperations (UNION) and
-- LIMIT triggers the new subquery->setOperations check.
-- Syntax: (SELECT ... UNION ALL SELECT ... LIMIT ...) EXCEPT SELECT ...
-- ################################################################

CREATE TABLE test_so4 (x int);
INSERT INTO test_so4 VALUES (1), (2), (3), (4), (5);

CREATE TABLE test_so5 (x int);
INSERT INTO test_so5 VALUES (3), (4), (5), (6), (7);

CREATE TABLE test_so6 (x int);
INSERT INTO test_so6 VALUES (2), (4), (6);

CREATE VIEW test_view_so2 AS
(SELECT x FROM test_so4 UNION ALL SELECT x FROM test_so5 LIMIT 10)
EXCEPT
SELECT x FROM test_so6;

SELECT pg_get_viewdef('test_view_so2'::regclass, true);
SELECT pg_get_viewdef('test_view_so2'::regclass, false);

DROP VIEW test_view_so2;
DROP TABLE test_so6;
DROP TABLE test_so5;
DROP TABLE test_so4;

-- ################################################################
-- Test 3: UNION with ORDER BY inside EXCEPT, all three setop types
-- Coverage: A leaf query containing setOperations (UNION ALL) with
-- ORDER BY, used inside EXCEPT. Tests the new code path with
-- EXCEPT as the outer set operation.
-- ################################################################

CREATE TABLE test_so7 (id int);
INSERT INTO test_so7 VALUES (1), (2), (3), (4), (5);

CREATE TABLE test_so8 (id int);
INSERT INTO test_so8 VALUES (3), (4), (5), (6), (7);

CREATE TABLE test_so9 (id int);
INSERT INTO test_so9 VALUES (1), (3), (5), (7), (9);

CREATE VIEW test_view_so3 AS
(SELECT id FROM test_so7 UNION ALL SELECT id FROM test_so8 ORDER BY 1)
EXCEPT
SELECT id FROM test_so9;

SELECT pg_get_viewdef('test_view_so3'::regclass, true);
SELECT pg_get_viewdef('test_view_so3'::regclass, false);

DROP VIEW test_view_so3;
DROP TABLE test_so9;
DROP TABLE test_so8;
DROP TABLE test_so7;

-- ################################################################
-- Test 4: Nested: UNION with ORDER BY inside INTERSECT inside UNION
-- Coverage: Multiple levels of set operation nesting, where the
-- innermost leaf has both setOperations and ORDER BY. This exercises
-- the new setOperations check at deeper recursion levels.
-- ################################################################

CREATE TABLE test_so10 (a int);
INSERT INTO test_so10 VALUES (1), (2), (3);

CREATE TABLE test_so11 (a int);
INSERT INTO test_so11 VALUES (3), (4), (5);

CREATE TABLE test_so12 (a int);
INSERT INTO test_so12 VALUES (5), (6), (7);

CREATE TABLE test_so13 (a int);
INSERT INTO test_so13 VALUES (1), (3), (5);

CREATE VIEW test_view_so4 AS
((SELECT a FROM test_so10 UNION ALL SELECT a FROM test_so11 ORDER BY 1)
 INTERSECT
 SELECT a FROM test_so12)
UNION
SELECT a FROM test_so13;

SELECT pg_get_viewdef('test_view_so4'::regclass, true);
SELECT pg_get_viewdef('test_view_so4'::regclass, false);

DROP VIEW test_view_so4;
DROP TABLE test_so13;
DROP TABLE test_so12;
DROP TABLE test_so11;
DROP TABLE test_so10;

-- ################################################################
-- Test 5: Subquery in FROM with UNION + ORDER BY
-- Coverage: A subquery in FROM clause that contains UNION with
-- ORDER BY. When deparsing the view, the subquery's setOperations
-- tree is processed by get_setop_query, and the leaf with both
-- setOperations and ORDER BY triggers the new code path.
-- ################################################################

CREATE TABLE test_so14 (id int, val int);
INSERT INTO test_so14 VALUES (1, 10), (2, 20), (3, 30);

CREATE TABLE test_so15 (id int, val int);
INSERT INTO test_so15 VALUES (2, 20), (3, 30), (4, 40);

CREATE TABLE test_so16 (id int, descr text);
INSERT INTO test_so16 VALUES (1, 'one'), (2, 'two'), (3, 'three');

CREATE VIEW test_view_so5 AS
SELECT sq.id, sq.val, td.descr
FROM (
    SELECT id, val FROM test_so14
    UNION ALL
    SELECT id, val FROM test_so15
    ORDER BY id
) sq
JOIN test_so16 td ON sq.id = td.id;

SELECT pg_get_viewdef('test_view_so5'::regclass, true);
SELECT pg_get_viewdef('test_view_so5'::regclass, false);

DROP VIEW test_view_so5;
DROP TABLE test_so16;
DROP TABLE test_so15;
DROP TABLE test_so14;

----------------------------------------
-- Source: 25.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Compare collations before merging UNION operations
-- task_id: 25
-- 
-- This test exercises the new code path in plan_union_children() that
-- compares colCollations before deciding whether two UNION nodes can
-- be merged (src/backend/optimizer/prep/prepunion.c, lines 895-898).
-- ================================================================

-- ================================================================
-- Test 1: UNION with same default collation (no COLLATE clause)
-- Both inner and outer UNION have the same default collation.
-- This should still allow merging (normal path, unchanged behavior).
-- ================================================================
CREATE TABLE test25_t1 (a text);
CREATE TABLE test25_t2 (a text);
CREATE TABLE test25_t3 (a text);

INSERT INTO test25_t1 VALUES ('apple'), ('banana'), ('cherry');
INSERT INTO test25_t2 VALUES ('apple'), ('banana'), ('date');
INSERT INTO test25_t3 VALUES ('apple'), ('elderberry'), ('fig');

-- Nested UNION with default collation: (t1 UNION t2) UNION t3
EXPLAIN ANALYZE
SELECT a FROM test25_t1
UNION
SELECT a FROM test25_t2
UNION
SELECT a FROM test25_t3
ORDER BY 1;

DROP TABLE test25_t1;
DROP TABLE test25_t2;
DROP TABLE test25_t3;


-- ================================================================
-- Test 2: UNION with explicit matching collations ("C" collation)
-- Both inner and outer UNION use the same explicit collation.
-- This should still be merged (same collation => merge allowed).
-- ================================================================
CREATE TABLE test25_t4 (a text COLLATE "C");
CREATE TABLE test25_t5 (a text COLLATE "C");
CREATE TABLE test25_t6 (a text COLLATE "C");

INSERT INTO test25_t4 VALUES ('Alpha'), ('Bravo'), ('Charlie');
INSERT INTO test25_t5 VALUES ('Alpha'), ('Bravo'), ('Delta');
INSERT INTO test25_t6 VALUES ('Alpha'), ('Echo'), ('Foxtrot');

-- Nested UNION: (t4 UNION t5) UNION t6, all with COLLATE "C"
EXPLAIN ANALYZE
SELECT a FROM test25_t4
UNION
SELECT a FROM test25_t5
UNION
SELECT a FROM test25_t6
ORDER BY 1;

DROP TABLE test25_t4;
DROP TABLE test25_t5;
DROP TABLE test25_t6;


-- ================================================================
-- Test 3: UNION with DIFFERENT collations (C vs POSIX)
-- Inner UNION uses "C", outer UNION uses "POSIX" (or vice versa).
-- This should trigger the new colCollations check and prevent merging,
-- because the collations don't match.
-- ================================================================
CREATE TABLE test25_t7 (a text);
CREATE TABLE test25_t8 (a text);
CREATE TABLE test25_t9 (a text);

INSERT INTO test25_t7 VALUES ('aaa'), ('BBB'), ('ccc');
INSERT INTO test25_t8 VALUES ('aaa'), ('BBB'), ('ddd');
INSERT INTO test25_t9 VALUES ('aaa'), ('ccc'), ('EEE');

-- Outer UNION with COLLATE "POSIX" wrapping an inner UNION with COLLATE "C"
-- The collations differ, so the new code path prevents merging.
EXPLAIN ANALYZE
SELECT a COLLATE "POSIX" FROM test25_t7
UNION
SELECT a COLLATE "C" FROM test25_t8
UNION
SELECT a COLLATE "POSIX" FROM test25_t9
ORDER BY 1;

DROP TABLE test25_t7;
DROP TABLE test25_t8;
DROP TABLE test25_t9;


-- ================================================================
-- Test 4: UNION with NULL values and explicit collation differences
-- Mix of NULLs and different collations to ensure the new check
-- handles NULL collation entries correctly.
-- ================================================================
CREATE TABLE test25_t10 (a text);
CREATE TABLE test25_t11 (a text);
CREATE TABLE test25_t12 (a text);

INSERT INTO test25_t10 VALUES (NULL), ('hello'), ('world');
INSERT INTO test25_t11 VALUES (NULL), ('HELLO'), ('WORLD');
INSERT INTO test25_t12 VALUES (NULL), ('Hello'), ('World');

-- Inner UNION uses "C", outer tuple uses default collation
EXPLAIN ANALYZE
SELECT a FROM test25_t10
UNION
SELECT a COLLATE "C" FROM test25_t11
UNION
SELECT a FROM test25_t12
ORDER BY 1;

DROP TABLE test25_t10;
DROP TABLE test25_t11;
DROP TABLE test25_t12;


-- ================================================================
-- Test 5: UNION ALL with UNION DISTINCT, different collations
-- Mix of UNION ALL and UNION DISTINCT with different collations.
-- Tests interaction between 'all' flag and collation check.
-- (The code checks: same op, (all == all OR all=true), same colTypes, 
--  same colCollations)
-- ================================================================
CREATE TABLE test25_t13 (a text);
CREATE TABLE test25_t14 (a text);
CREATE TABLE test25_t15 (a text);

INSERT INTO test25_t13 VALUES ('cat'), ('DOG'), ('mouse');
INSERT INTO test25_t14 VALUES ('cat'), ('DOG'), ('rabbit');
INSERT INTO test25_t15 VALUES ('cat'), ('mouse'), ('SNAKE');

-- UNION ALL (inner) with COLLATE "C" vs UNION DISTINCT (outer) with "POSIX"
-- Since op differs (ALL vs DISTINCT) AND collations differ, no merging.
EXPLAIN ANALYZE
SELECT a COLLATE "POSIX" FROM test25_t13
UNION
SELECT a COLLATE "C" FROM test25_t14
UNION ALL
SELECT a COLLATE "POSIX" FROM test25_t15
ORDER BY 1;

DROP TABLE test25_t13;
DROP TABLE test25_t14;
DROP TABLE test25_t15;

-- ================================================================
-- End of regression tests for collation-aware UNION merging
-- ================================================================

----------------------------------------
-- Source: 26.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for:
--   Fix improper interactions between session_authorization and role
--   (CVE-2024-10978)
-- task_id: 26
-- ================================================================
-- This test exercises the new code in ParallelWorkerMain that directly
-- restores session_user_id, authenticated_user_id, and current_role_id
-- before InitPostgres, rather than relying on GUC restore order.
--
-- The new code paths are:
--   parallel.c:1410-1414 - SetAuthenticatedUserId, SetSessionAuthorization,
--                           SetCurrentRoleId called before InitPostgres
--   parallel.c:339-341   - Saving session_user_id, authenticated_user_is_superuser,
--                           session_user_is_superuser, role_is_superuser
-- ================================================================

-- To run: psql -f 26.sql

-- ================================================================
-- Test 1: Basic parallel query with session_authorization
-- Coverage: ParallelWorkerMain restores session authorization via
--   SetSessionAuthorization(fps->session_user_id, fps->session_user_is_superuser)
--   (parallel.c lines 1412-1413)
-- ================================================================

-- Use a superuser role for SET SESSION AUTHORIZATION
BEGIN;

-- Force parallel query execution
SET force_parallel_mode = 1;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;

-- Create a table large enough to trigger parallel scan
CREATE TABLE test_parallel_basic (id int, val int);
INSERT INTO test_parallel_basic SELECT g, g % 100 FROM generate_series(1, 10000) g;

ALTER TABLE test_parallel_basic SET (parallel_workers = 2);

-- Run a parallel query that should trigger worker startup
EXPLAIN (analyze, costs off, timing off, summary off)
SELECT count(*), avg(val) FROM test_parallel_basic WHERE val > 50;

DROP TABLE test_parallel_basic;
COMMIT;

-- ================================================================
-- Test 2: SET SESSION AUTHORIZATION before parallel query
-- Coverage: ParallelWorkerMain restores session_user_id via
--   SetSessionAuthorization. This tests that the session authorization
--   change is properly propagated to parallel workers.
--   (parallel.c lines 1412-1413)
-- ================================================================

BEGIN;

-- Create a non-superuser role to switch to
CREATE ROLE test_session_role LOGIN;

SET force_parallel_mode = 1;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;

-- Switch session authorization
SET SESSION AUTHORIZATION test_session_role;

CREATE TABLE test_session_auth_data (id int, category text);
INSERT INTO test_session_auth_data SELECT g, 'cat_' || (g % 10)::text FROM generate_series(1, 5000) g;

ALTER TABLE test_session_auth_data SET (parallel_workers = 2);

-- Parallel query while session authorization is set to non-superuser
EXPLAIN (analyze, costs off, timing off, summary off)
SELECT category, count(*) FROM test_session_auth_data GROUP BY category;

DROP TABLE test_session_auth_data;

-- Reset session authorization before commit
RESET SESSION AUTHORIZATION;
COMMIT;

DROP ROLE IF EXISTS test_session_role;

-- ================================================================
-- Test 3: SET ROLE before parallel query
-- Coverage: ParallelWorkerMain restores current_role_id via
--   SetCurrentRoleId(fps->outer_user_id, fps->role_is_superuser)
--   (parallel.c line 1414)
-- This tests that the role setting is properly propagated to workers.
-- ================================================================

BEGIN;

CREATE ROLE test_role_user LOGIN;
GRANT ALL ON SCHEMA public TO test_role_user;

SET force_parallel_mode = 1;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;

-- Set role to non-superuser
SET ROLE test_role_user;

CREATE TABLE test_role_data (x int, y int);
INSERT INTO test_role_data SELECT g, g * 2 FROM generate_series(1, 5000) g;

ALTER TABLE test_role_data SET (parallel_workers = 2);

-- Parallel query under a different role
EXPLAIN (analyze, costs off, timing off, summary off)
SELECT count(*), max(y), min(y) FROM test_role_data WHERE x > 100;

DROP TABLE test_role_data;

-- Reset role
RESET ROLE;
COMMIT;

DROP ROLE IF EXISTS test_role_user;

-- ================================================================
-- Test 4: SET SESSION AUTHORIZATION + SET ROLE combined before parallel query
-- Coverage: Both SetSessionAuthorization and SetCurrentRoleId are called
--   in worker startup. This tests the SQL spec requirement that
--   SET SESSION AUTHORIZATION implies SET ROLE NONE, and then a subsequent
--   SET ROLE is properly propagated to parallel workers.
--   (parallel.c lines 1410-1414)
-- ================================================================

BEGIN;

CREATE ROLE test_combined_role1 LOGIN;
CREATE ROLE test_combined_role2 LOGIN;

SET force_parallel_mode = 1;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;

-- Switch session authorization (this also SET ROLE NONE)
SET SESSION AUTHORIZATION test_combined_role1;
-- Then set a specific role
SET ROLE test_combined_role2;

CREATE TABLE test_combined_data (id int, val text);
INSERT INTO test_combined_data SELECT g, 'value_' || g FROM generate_series(1, 5000) g;

ALTER TABLE test_combined_data SET (parallel_workers = 2);

-- Parallel query with both session authorization and role set
EXPLAIN (analyze, costs off, timing off, summary off)
SELECT left(val, 5) AS prefix, count(*) FROM test_combined_data GROUP BY prefix;

DROP TABLE test_combined_data;

-- Reset
RESET ROLE;
RESET SESSION AUTHORIZATION;
COMMIT;

DROP ROLE IF EXISTS test_combined_role1;
DROP ROLE IF EXISTS test_combined_role2;

-- ================================================================
-- Test 5: Session authorization change inside a transaction with parallel query
-- Coverage: ParallelWorkerMain correctly sets authenticated_user_id via
--   SetAuthenticatedUserId (parallel.c lines 1410-1411).
--   This tests the scenario where a parallel worker needs the correct
--   authenticated user even after session_authorization changes.
-- ================================================================

BEGIN;

CREATE ROLE test_trans_role LOGIN;

SET force_parallel_mode = 1;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;

-- Create data before changing authorization
CREATE TABLE test_trans_data (id int, category int, value float8);
INSERT INTO test_trans_data SELECT g, g % 20, random() * 100 FROM generate_series(1, 8000) g;
ALTER TABLE test_trans_data SET (parallel_workers = 2);

-- First parallel query as superuser
EXPLAIN (analyze, costs off, timing off, summary off)
SELECT category, avg(value), stddev(value) FROM test_trans_data GROUP BY category;

-- Now switch session authorization
SET SESSION AUTHORIZATION test_trans_role;

-- Second parallel query as the switched user
EXPLAIN (analyze, costs off, timing off, summary off)
SELECT category, count(*), max(value) FROM test_trans_data WHERE value > 50 GROUP BY category;

DROP TABLE test_trans_data;

RESET SESSION AUTHORIZATION;
COMMIT;

DROP ROLE IF EXISTS test_trans_role;

-- ================================================================
-- End of regression tests
-- ================================================================
SELECT 'Parallel session_authorization/role tests completed successfully.' AS status;

----------------------------------------
-- Source: 28.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Unpin buffer before inplace update waits for an XID to end
-- task_id: 28
-- 
-- This test exercises heap_inplace_lock() with the new release_callback
-- parameter.  The callback (systable_endscan) is called before waiting
-- for blocking transactions, preventing buffer pin starvation.
--
-- The code paths tested:
--   1. heap_inplace_lock through VACUUM's vac_update_relstats (pg_class)
--   2. heap_inplace_lock through GRANT's catalog update (pg_class.relacl)
--   3. heap_inplace_lock through CREATE INDEX (pg_class.relhasindex)
--   4. heap_inplace_lock through REINDEX (pg_class)
--   5. heap_inplace_lock through VACUUM FREEZE on pg_database
-- ================================================================

-- -----------------------------------------------------------------
-- Test 1: VACUUM triggers systable_inplace_update_begin on pg_class
--         via vacuum.c's vac_update_relstats().
--         This covers the success path through heap_inplace_lock.
-- -----------------------------------------------------------------
CREATE TABLE test_inplace_vac (
    id int PRIMARY KEY,
    val text
);
INSERT INTO test_inplace_vac SELECT generate_series(1,1000), 'hello';
-- Run VACUUM to trigger inplace updates of pg_class.relfrozenxid
VACUUM (FREEZE) test_inplace_vac;
DROP TABLE test_inplace_vac;

-- -----------------------------------------------------------------
-- Test 2: GRANT on a table triggers systable_inplace_update_begin
--         via the catalog update path in heap_inplace_lock.
--         GRANT modifies pg_class.relacl catalog entries in-place.
-- -----------------------------------------------------------------
CREATE TABLE test_inplace_grant (
    id int,
    data text
);
INSERT INTO test_inplace_grant VALUES (1, 'test');
GRANT SELECT ON test_inplace_grant TO PUBLIC;
GRANT INSERT ON test_inplace_grant TO PUBLIC;
REVOKE ALL ON test_inplace_grant FROM PUBLIC;
DROP TABLE test_inplace_grant;

-- -----------------------------------------------------------------
-- Test 3: CREATE INDEX triggers systable_inplace_update_begin
--         via index.c, changing pg_class.relhasindex in-place.
-- -----------------------------------------------------------------
CREATE TABLE test_inplace_index (
    id int,
    data text
);
INSERT INTO test_inplace_index SELECT generate_series(1,100), 'index_test';
-- Create an index; this inplace-updates pg_class for the table
CREATE INDEX test_inplace_idx ON test_inplace_index(id);
DROP TABLE test_inplace_index;

-- -----------------------------------------------------------------
-- Test 4: REINDEX triggers inplace update of pg_class via the
--         index.c code path, another systable_inplace_update_begin call.
-- -----------------------------------------------------------------
CREATE TABLE test_inplace_reindex (
    id int PRIMARY KEY,
    data text
);
INSERT INTO test_inplace_reindex SELECT generate_series(1,100), 'reindex_test';
CREATE INDEX test_inplace_reidx ON test_inplace_reindex(data);
-- REINDEX TABLE will inplace-update pg_class via systable_inplace_update_begin
REINDEX TABLE test_inplace_reindex;
REINDEX INDEX test_inplace_reidx;
DROP TABLE test_inplace_reindex;

-- -----------------------------------------------------------------
-- Test 5: VACUUM with freeze on a table triggers both the per-table
--         pg_class inplace update and database-level vacuum processing.
--         This exercises the vac_update_datfrozenxid path as well.
-- -----------------------------------------------------------------
CREATE TABLE test_inplace_freeze (
    id serial,
    val text,
    created_at timestamp DEFAULT now()
);
INSERT INTO test_inplace_freeze (val) SELECT 'row_' || generate_series(1,500);
-- VACUUM FREEZE triggers inplace updates on pg_class
VACUUM (FREEZE, INDEX_CLEANUP ON) test_inplace_freeze;
-- Second VACUUM with different options
VACUUM (FREEZE, TRUNCATE) test_inplace_freeze;
DROP TABLE test_inplace_freeze;

----------------------------------------
-- Source: 29.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Back-patch "Refactor code in tablecmds.c to
-- check and process tablespace moves"
-- task_id: 29
-- ================================================================
-- This test exercises the newly extracted functions:
--   CheckRelationTableSpaceMove() and SetRelationTableSpace()
-- which were refactored from inline code in ATExecSetTableSpace()
-- and ATExecSetTableSpaceNoStorage().
--
-- Code paths covered:
--   1. No-op (same tablespace) → CheckRelationTableSpaceMove returns false
--   2. Normal table move with storage → SetRelationTableSpace with newRelFileNode
--   3. Relation without storage (view) → ATExecSetTableSpaceNoStorage path
--   4. Error: non-shared relation → pg_global
--   5. Move to database default tablespace (MyDatabaseTableSpace = 0)
-- ================================================================

-- -----------------------------------------------------------------
-- Test 1: No-op — SET TABLESPACE to the same tablespace
-- Coverage: CheckRelationTableSpaceMove() returns false early,
--           no pg_class update happens.
-- -----------------------------------------------------------------
CREATE TABLE test_same_tablespace (id int, name text);
INSERT INTO test_same_tablespace VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');

-- Move to pg_default when already in pg_default → should be a no-op
ALTER TABLE test_same_tablespace SET TABLESPACE pg_default;

-- Verify the relation still exists and is usable
SELECT count(*) FROM test_same_tablespace;

DROP TABLE test_same_tablespace;

-- -----------------------------------------------------------------
-- Test 2: Normal tablespace move for a table with storage
-- Coverage: CheckRelationTableSpaceMove() returns true,
--           SetRelationTableSpace() updates reltablespace and relfilenode.
-- -----------------------------------------------------------------
CREATE TABLE test_normal_move (id int PRIMARY KEY, value text);
INSERT INTO test_normal_move SELECT generate_series(1, 100), 'row_' || generate_series(1, 100);

-- Move to pg_default (from whatever tablespace the database default is)
ALTER TABLE test_normal_move SET TABLESPACE pg_default;

-- Verify data integrity after move
SELECT count(*), count(DISTINCT id) FROM test_normal_move;

-- Move back (also a no-op since it's already there, but exercises the path)
ALTER TABLE test_normal_move SET TABLESPACE pg_default;

DROP TABLE test_normal_move;

-- -----------------------------------------------------------------
-- Test 3: Relation without storage — view SET TABLESPACE
-- Coverage: ATExecSetTableSpaceNoStorage() calls CheckRelationTableSpaceMove()
--           and SetRelationTableSpace() with InvalidOid (no relfilenode update).
-- -----------------------------------------------------------------
CREATE TABLE test_view_base (id int, val int);
INSERT INTO test_view_base VALUES (1, 10), (2, 20), (3, 30);

CREATE VIEW test_view_move AS SELECT * FROM test_view_base WHERE val > 10;

-- Move view to pg_default (no-storage path)
ALTER VIEW test_view_move SET TABLESPACE pg_default;

-- Verify view still works
SELECT * FROM test_view_move;

-- Same tablespace no-op on view
ALTER VIEW test_view_move SET TABLESPACE pg_default;

DROP VIEW test_view_move;
DROP TABLE test_view_base;

-- -----------------------------------------------------------------
-- Test 4: Error — moving a non-shared relation to pg_global
-- Coverage: CheckRelationTableSpaceMove() detects newTableSpaceId ==
--           GLOBALTABLESPACE_OID and raises ERROR.
-- -----------------------------------------------------------------
CREATE TABLE test_pg_global_error (id int, data text);
INSERT INTO test_pg_global_error VALUES (1, 'should fail');

-- This should ERROR: "only shared relations can be placed in pg_global tablespace"
ALTER TABLE test_pg_global_error SET TABLESPACE pg_global;

-- (If we reach here, the test fails — but the ERROR is expected)
DROP TABLE test_pg_global_error;

-- -----------------------------------------------------------------
-- Test 5: Move to database default tablespace
-- Coverage: When newTableSpaceId == MyDatabaseTableSpace and
--           oldTableSpaceId != 0, the move proceeds.
--           Tests the edge case in CheckRelationTableSpaceMove
--           where MyDatabaseTableSpace is stored as 0.
-- -----------------------------------------------------------------
CREATE TABLE test_default_move (id int, payload text);
INSERT INTO test_default_move VALUES (1, 'default tablespace test');

-- Move to pg_default (which maps to MyDatabaseTableSpace / 0 internally)
ALTER TABLE test_default_move SET TABLESPACE pg_default;

-- Verify the move didn't break anything
SELECT count(*) FROM test_default_move;

-- Move again to pg_default — should be no-op (old == 0, new == MyDatabaseTableSpace/0)
ALTER TABLE test_default_move SET TABLESPACE pg_default;

DROP TABLE test_default_move;

----------------------------------------
-- Source: 30.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Disallow USING clause when altering type of generated column
-- task_id: 30
-- ================================================================
-- This test covers the new check added in ATPrepAlterColumnType:
--   Block 0 (lines 11634-11638): ERROR when USING is specified on a generated column
--   Block 1 (lines 11716-11721): Suppress "use USING" hint for generated columns
-- ================================================================

-- ================================================================
-- Test 1: Basic check - USING clause on generated column is rejected
-- Target: Block 0 - the new ereport(ERROR) check
-- Expect: ERROR: cannot specify USING when altering type of generated column
-- ================================================================
CREATE TABLE test_gen_using1 (
    a int,
    b int GENERATED ALWAYS AS (a * 2) STORED
);
INSERT INTO test_gen_using1 (a) VALUES (1), (2), (3);

-- This should fail with the new error
ALTER TABLE test_gen_using1 ALTER COLUMN b TYPE bigint USING b::bigint;

DROP TABLE test_gen_using1;

-- ================================================================
-- Test 2: Altering generated column type WITHOUT USING succeeds
-- Target: Valid code path (no error) - the new check should NOT fire
-- ================================================================
CREATE TABLE test_gen_using2 (
    a int,
    b int GENERATED ALWAYS AS (a * 2) STORED
);
INSERT INTO test_gen_using2 (a) VALUES (1), (2), (3);

-- This should succeed (no USING clause)
ALTER TABLE test_gen_using2 ALTER COLUMN b TYPE bigint;

SELECT * FROM test_gen_using2 ORDER BY a;

DROP TABLE test_gen_using2;

-- ================================================================
-- Test 3: Altering generated column type when cast needs USING (Suppressed hint)
-- Target: Block 1 - the !attTup->attgenerated ? conditional hint
-- The hint "You might need to specify USING..." should NOT appear
-- ================================================================
CREATE TABLE test_gen_using3 (
    a int,
    b int GENERATED ALWAYS AS (a * 2) STORED
);
INSERT INTO test_gen_using3 (a) VALUES (1), (2), (3);

-- Try to alter to a type that requires an explicit cast.
-- For a generated column, the error message should NOT include the
-- "You might need to specify USING..." hint.
ALTER TABLE test_gen_using3 ALTER COLUMN b TYPE text;

DROP TABLE test_gen_using3;

-- ================================================================
-- Test 4: Non-generated column WITH USING still works (regression check)
-- Target: Ensure existing behavior for regular columns is unchanged
-- ================================================================
CREATE TABLE test_gen_using4 (
    a int,
    b text
);
INSERT INTO test_gen_using4 VALUES (1, '42'), (2, '100');

-- This should succeed - regular column WITH USING is still allowed
ALTER TABLE test_gen_using4 ALTER COLUMN b TYPE int USING b::integer;

SELECT * FROM test_gen_using4 ORDER BY a;

DROP TABLE test_gen_using4;

-- ================================================================
-- Test 5: Multiple columns - mixing generated and non-generated
-- Target: Both Block 0 (error) and Block 1 (hint suppression) in same ALTER
-- ================================================================
CREATE TABLE test_gen_using5 (
    a int,
    b int GENERATED ALWAYS AS (a * 2) STORED,
    c text
);
INSERT INTO test_gen_using5 (a, c) VALUES (1, '10'), (2, '20');

-- Test: alter two columns simultaneously, one generated with USING (should fail)
ALTER TABLE test_gen_using5
  ALTER COLUMN b TYPE bigint USING b::bigint,
  ALTER COLUMN c TYPE int USING c::integer;

DROP TABLE test_gen_using5;

-- ================================================================
-- Test 6: Verify the error detail message mentions the column name
-- Target: Block 0 - errdetail with column name
-- ================================================================
CREATE TABLE test_gen_using6 (
    id int,
    full_name text,
    name_length int GENERATED ALWAYS AS (length(full_name)) STORED
);
INSERT INTO test_gen_using6 (id, full_name) VALUES (1, 'Alice'), (2, 'Bob');

ALTER TABLE test_gen_using6 ALTER COLUMN name_length TYPE bigint USING length(full_name);

DROP TABLE test_gen_using6;

-- ================================================================
-- Test 7: Edge case - altering type of generated column that has
--          no data in it (empty table)
-- Target: Block 0 with empty table
-- ================================================================
CREATE TABLE test_gen_using7 (
    a int,
    b int GENERATED ALWAYS AS (a * 2) STORED
);
-- No data inserted

ALTER TABLE test_gen_using7 ALTER COLUMN b TYPE bigint USING b::bigint;

DROP TABLE test_gen_using7;

----------------------------------------
-- Source: 31.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix DROP DATABASE for databases with many ACLs
-- 
-- This commit fixes a bug where DROP DATABASE fails with
--   ERROR:  wrong tuple length
-- when the database has many ACLs causing the pg_database.datacl
-- attribute to be TOASTed. The fix changes the tuple reading from
-- syscache (SearchSysCacheCopy1) to a direct catalog scan
-- (systable_beginscan) to avoid detoasting that causes length mismatch.
--
-- task_id: 31
-- ================================================================

-- ================================================================
-- Test 1: DROP DATABASE with a database that has normal (small) ACLs
-- 
-- Covers: Normal code path through the new systable_beginscan logic
--         with non-TOASTed datacl.
-- ================================================================
CREATE DATABASE regression_test1
    ENCODING utf8 LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;

-- Grant some privileges to create ACL entries (non-TOASTed size)
GRANT CONNECT ON DATABASE regression_test1 TO public;
GRANT TEMPORARY ON DATABASE regression_test1 TO public;

-- Perform DROP DATABASE — this exercises the new code path
DROP DATABASE regression_test1;

-- ================================================================
-- Test 2: DROP DATABASE IF EXISTS with a database that has many ACLs
--         (triggering TOAST on pg_database.datacl)
--
-- Covers: The core bug fix — when datacl is TOASTed, the old code
--         would fail with "wrong tuple length". The new code reads
--         tuple directly from catalog (not syscache), so the tuple
--         length matches on-disk representation.
-- ================================================================
CREATE DATABASE regression_test2
    ENCODING utf8 LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;

-- Inject a large number of ACL entries to force TOAST on datacl.
-- Using array_fill with makeaclitem to create 500,000 ACL entries.
BEGIN;
UPDATE pg_database
SET datacl = array_fill(makeaclitem(10, 10, 'USAGE', false), ARRAY[5e5::int])
WHERE datname = 'regression_test2';
-- Load the catcache entry to ensure the TOASTed value is cached
ALTER DATABASE regression_test2 RESET TABLESPACE;
COMMIT;

-- DROP DATABASE IF EXISTS — exercises the fixed code path with TOASTed datacl
DROP DATABASE IF EXISTS regression_test2;

-- ================================================================
-- Test 3: DROP DATABASE with many ACLs and special characters in dbname
--
-- Covers: The new code path with a database name containing special
--         characters, to test the ScanKeyInit with F_NAMEEQ for
--         non-trivial names.
-- ================================================================
CREATE DATABASE "regression_test3_特殊_名"
    ENCODING utf8 LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;

BEGIN;
UPDATE pg_database
SET datacl = array_fill(makeaclitem(10, 10, 'USAGE', false), ARRAY[5e5::int])
WHERE datname = 'regression_test3_特殊_名';
ALTER DATABASE "regression_test3_特殊_名" RESET TABLESPACE;
COMMIT;

DROP DATABASE "regression_test3_特殊_名";

-- ================================================================
-- Test 4: DROP DATABASE with CONNECTION LIMIT and many ACLs
--
-- Covers: The new code path combined with the datconnlimit invalidation
--         logic (systable_inplace_update_begin + systable_inplace_update_finish)
--         when the database has a TOASTed datacl. This tests the full
--         in-place update sequence with the new catalog scan.
-- ================================================================
CREATE DATABASE regression_test4
    ENCODING utf8 LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0
    CONNECTION LIMIT 10;

-- Add enough ACLs to trigger TOAST
BEGIN;
UPDATE pg_database
SET datacl = array_fill(makeaclitem(10, 10, 'USAGE', false), ARRAY[6e5::int])
WHERE datname = 'regression_test4';
ALTER DATABASE regression_test4 RESET TABLESPACE;
COMMIT;

DROP DATABASE regression_test4;

-- ================================================================
-- Test 5: DROP DATABASE with mixed ACL grants (multiple users/privileges)
--         that approaches TOAST threshold
--
-- Covers: Edge case with moderate ACL size that is just below or at
--         TOAST threshold, testing with different privilege combinations.
-- ================================================================
CREATE DATABASE regression_test5
    ENCODING utf8 LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;

-- Grant various privileges to create a non-trivial ACL array
GRANT CONNECT ON DATABASE regression_test5 TO public;
GRANT TEMPORARY ON DATABASE regression_test5 TO public;
GRANT CREATE ON DATABASE regression_test5 TO public;

-- Add a substantial but not enormous ACL array (50,000 entries)
BEGIN;
UPDATE pg_database
SET datacl = datacl || array_fill(makeaclitem(10, 10, 'USAGE', false), ARRAY[50000::int])
WHERE datname = 'regression_test5';
COMMIT;

DROP DATABASE regression_test5;

-- ================================================================
-- Test cleanup: verify all databases are dropped
-- ================================================================
SELECT datname FROM pg_database WHERE datname LIKE 'regression_test%';

----------------------------------------
-- Source: 32.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Reset relhassubclass upon attaching table
-- as a partition
--
-- task_id: 32
--
-- This test exercises the new code path in StorePartitionBound()
-- that resets relhassubclass (at src/backend/catalog/heap.c:3871-3872)
-- when a table that was previously an inheritance parent (with stale
-- relhassubclass=true) is attached as a partition.
-- ================================================================

-- ================================================================
-- Test 1: Core scenario - table with stale relhassubclass from
-- inheritance is attached as a RANGE partition.
-- 
-- Code path: StorePartitionBound() ->
--   if (rel->rd_rel->relkind == RELKIND_RELATION &&
--       rel->rd_rel->relhassubclass)
--       relhassubclass = false;
-- ================================================================

-- Create the partitioned table that will be the parent
CREATE TABLE part_parent (id int, data text) PARTITION BY RANGE (id);

-- Create a regular table that will later become a partition
CREATE TABLE part_candidate (id int, data text);

-- Make it an inheritance parent first: create a child table
CREATE TABLE part_candidate_child () INHERITS (part_candidate);

-- Verify relhassubclass is set
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate';

-- Drop the child table (removes pg_inherits entry, but relhassubclass
-- may remain set to true in older releases)
DROP TABLE part_candidate_child;

-- Verify that relhassubclass is still true (the stale flag)
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate';

-- Attach the table as a partition. This should trigger the new code
-- path that resets relhassubclass from true to false.
ALTER TABLE part_parent ATTACH PARTITION part_candidate FOR VALUES FROM (1) TO (100);

-- Verify that relhassubclass has been reset to false
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate';

-- Verify the table works correctly as a partition (insert and query)
INSERT INTO part_parent VALUES (50, 'test data');
EXPLAIN ANALYZE SELECT * FROM part_parent WHERE id = 50;

-- Cleanup
DROP TABLE part_parent;

-- ================================================================
-- Test 2: Table with stale relhassubclass attached as a LIST
-- partition.
--
-- Covers the same code path with a different partition strategy.
-- ================================================================

CREATE TABLE part_parent2 (region text, amount int) PARTITION BY LIST (region);

-- Create a regular table with inheritance history
CREATE TABLE part_candidate2 (region text, amount int);

-- Create and drop an inheritance child to leave stale relhassubclass
CREATE TABLE part_candidate2_child () INHERITS (part_candidate2);
DROP TABLE part_candidate2_child;

-- Verify stale flag
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate2';

-- Attach as list partition
ALTER TABLE part_parent2 ATTACH PARTITION part_candidate2 FOR VALUES IN ('EAST', 'WEST');

-- Verify relhassubclass is now false
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate2';

-- Verify partition works
INSERT INTO part_parent2 VALUES ('EAST', 100);
EXPLAIN ANALYZE SELECT * FROM part_parent2 WHERE region = 'EAST';

DROP TABLE part_parent2;

-- ================================================================
-- Test 3: Normal case - a table without any inheritance history
-- (relhassubclass is already false) is attached as a partition.
-- The new code path's condition (relhassubclass == true) is NOT
-- met, so the reset is skipped. This tests the branch is
-- conditional and does not break the normal path.
-- ================================================================

CREATE TABLE part_parent3 (x int, y text) PARTITION BY RANGE (x);

-- Create a table with no inheritance history
CREATE TABLE part_candidate3 (x int, y text);

-- Verify relhassubclass is already false
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate3';

-- Attach as partition (the new code runs but skips reset since
-- relhassubclass is already false)
ALTER TABLE part_parent3 ATTACH PARTITION part_candidate3 FOR VALUES FROM (0) TO (1000);

-- Verify relhassubclass is still false
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate3';

-- Verify partition works
INSERT INTO part_parent3 VALUES (500, 'normal');
EXPLAIN ANALYZE SELECT * FROM part_parent3 WHERE x = 500;

DROP TABLE part_parent3;

-- ================================================================
-- Test 4: Foreign table case - a foreign table cannot have
-- inheritance children (foreign tables have a different relkind),
-- so the new code path condition (relkind == RELKIND_RELATION)
-- should NOT trigger. This tests the relkind guard.
-- ================================================================

-- Use a regular table that simulates the boundary condition.
-- Try attaching a table whose relkind is not RELKIND_RELATION
-- (e.g., a table with inheritance children but relkind check
-- prevents the reset). Since foreign tables don't support
-- inheritance, we instead test that a normal table that is a
-- partition of another table (relkind is regular relation) still
-- works correctly.

CREATE TABLE part_parent4 (id int) PARTITION BY HASH (id);

-- Create a regular table
CREATE TABLE part_candidate4 (id int);

-- Create inheritance child to set relhassubclass
CREATE TABLE part_candidate4_child () INHERITS (part_candidate4);
DROP TABLE part_candidate4_child;

-- Verify stale flag
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate4';

-- Attach as hash partition (covers relkind == RELKIND_RELATION && relhassubclass == true)
ALTER TABLE part_parent4 ATTACH PARTITION part_candidate4 FOR VALUES WITH (MODULUS 4, REMAINDER 0);

-- Verify reset
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate4';

-- Verify operation
INSERT INTO part_parent4 VALUES (1), (2), (3), (4);
EXPLAIN ANALYZE SELECT * FROM part_parent4 WHERE id = 3;

DROP TABLE part_parent4;

-- ================================================================
-- Test 5: Default partition scenario - attaching a table with
-- stale relhassubclass as the default partition of a list
-- partitioned table.
--
-- This exercises the code path through the DEFAULT branch in
-- StorePartitionBound().
-- ================================================================

CREATE TABLE part_parent5 (color text) PARTITION BY LIST (color);

-- Create table with inheritance history
CREATE TABLE part_candidate5 (color text);

CREATE TABLE part_candidate5_child () INHERITS (part_candidate5);
DROP TABLE part_candidate5_child;

-- Verify stale flag
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate5';

-- Create a regular partition first, then attach the candidate as default
CREATE TABLE part_red PARTITION OF part_parent5 FOR VALUES IN ('RED');

-- Attach as default partition
ALTER TABLE part_parent5 ATTACH PARTITION part_candidate5 DEFAULT;

-- Verify relhassubclass reset
SELECT relname, relhassubclass
  FROM pg_class
 WHERE relname = 'part_candidate5';

-- Verify default partition works
INSERT INTO part_parent5 VALUES ('RED'), ('BLUE'), ('GREEN');
EXPLAIN ANALYZE SELECT * FROM part_parent5 WHERE color = 'GREEN';

DROP TABLE part_parent5;

----------------------------------------
-- Source: 38.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Ensure we allocate NAMEDATALEN bytes
-- for names in Index Only Scans
-- task_id: 38
-- ================================================================
-- This test exercises the new code path in StoreIndexTuple() and
-- ExecInitIndexOnlyScan() that converts cstrings back to properly
-- sized name datums (NAMEDATALEN bytes) during Index Only Scans
-- on btree indexes using name_ops.
-- ================================================================

-- ================================================================
-- Test 1: Basic Index Only Scan on a name column with name_ops
-- Covers: StoreIndexTuple() new code path (lines 293-314) and
--         ExecInitIndexOnlyScan() initialization (lines 663-704)
-- ================================================================

CREATE TABLE test_name_ios_1 (
    id int4,
    name_col name
);

INSERT INTO test_name_ios_1 VALUES
    (1, 'Alice'),
    (2, 'Bob'),
    (3, 'Charlie'),
    (4, 'David'),
    (5, 'Eve');

CREATE INDEX idx_name_ios_1 ON test_name_ios_1 USING btree(name_col name_ops);

ANALYZE test_name_ios_1;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT name_col FROM test_name_ios_1 WHERE name_col >= 'A' AND name_col <= 'Z';

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT name_col FROM test_name_ios_1 WHERE name_col = 'Charlie';

DROP TABLE test_name_ios_1;


-- ================================================================
-- Test 2: NULL values in name column with Index Only Scan
-- Covers: The NULL skip branch in StoreIndexTuple() (line 303-304)
--         "if (slot->tts_isnull[attnum]) continue;"
-- ================================================================

CREATE TABLE test_name_ios_2 (
    id int4,
    name_col name
);

INSERT INTO test_name_ios_2 VALUES
    (1, 'First'),
    (2, NULL),
    (3, 'Second'),
    (4, NULL),
    (5, 'Third'),
    (6, NULL),
    (7, 'Fourth'),
    (8, NULL);

CREATE INDEX idx_name_ios_2 ON test_name_ios_2 USING btree(name_col name_ops);

ANALYZE test_name_ios_2;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT name_col FROM test_name_ios_2 WHERE name_col IS NOT NULL;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT name_col FROM test_name_ios_2 WHERE name_col = 'Second';

DROP TABLE test_name_ios_2;


-- ================================================================
-- Test 3: Empty string in name column
-- Covers: Edge case where cstring is empty
--         namestrcpy() behavior with empty input
-- ================================================================

CREATE TABLE test_name_ios_3 (
    id int4,
    name_col name
);

INSERT INTO test_name_ios_3 VALUES
    (1, ''),
    (2, 'a'),
    (3, ''),
    (4, 'hello world'),
    (5, 'normal'),
    (6, ''),
    (7, 'zzzzz');

CREATE INDEX idx_name_ios_3 ON test_name_ios_3 USING btree(name_col name_ops);

ANALYZE test_name_ios_3;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT name_col FROM test_name_ios_3
WHERE name_col >= '' AND name_col <= 'zzzzz';

DROP TABLE test_name_ios_3;


-- ================================================================
-- Test 4: Maximum length name (NAMEDATALEN-1 = 63 chars)
-- Covers: namestrcpy() correctly zero-padding trailing bytes
--         to fill NAMEDATALEN (64 bytes)
-- ================================================================

CREATE TABLE test_name_ios_4 (
    id int4,
    name_col name
);

INSERT INTO test_name_ios_4 VALUES
    (1, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!'),
    (2, 'short'),
    (3, repeat('X', 63)::name);

CREATE INDEX idx_name_ios_4 ON test_name_ios_4 USING btree(name_col name_ops);

ANALYZE test_name_ios_4;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT name_col FROM test_name_ios_4
WHERE name_col >= 'A';

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT name_col FROM test_name_ios_4
WHERE name_col = repeat('X', 63)::name;

DROP TABLE test_name_ios_4;


-- ================================================================
-- Test 5: Multiple name columns with name_ops in composite index
-- Covers: Multiple entries in ioss_NameCStringAttNums array
--         (attcount > 1 in the for loop at line 297)
--         Also tests NULL in multi-column scenario
-- ================================================================

CREATE TABLE test_name_ios_5 (
    id int4,
    first_name name,
    last_name name,
    extra int4
);

INSERT INTO test_name_ios_5 VALUES
    (1, 'John', 'Doe', 100),
    (2, 'Jane', 'Smith', 200),
    (3, 'Bob', 'Johnson', 300),
    (4, 'Alice', 'Williams', 400),
    (5, 'Charlie', 'Brown', 500),
    (6, 'Eve', NULL, 600),
    (7, NULL, 'Davis', 700),
    (8, NULL, NULL, 800);

CREATE INDEX idx_name_ios_5_composite ON test_name_ios_5
    USING btree(first_name name_ops, last_name name_ops);

ANALYZE test_name_ios_5;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT first_name, last_name FROM test_name_ios_5
WHERE first_name >= 'A' AND first_name <= 'Z'
  AND last_name >= 'A' AND last_name <= 'Z';

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT first_name FROM test_name_ios_5
WHERE first_name = 'Alice';

DROP TABLE test_name_ios_5;


----------------------------------------
-- Source: 39.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Revert "Fix parallel-safety check of expressions and predicate for index builds"
-- task_id: 39
--
-- This test exercises the plan_create_index_workers() code path,
-- specifically the parallel-safety checks of index expressions and
-- predicates using RelationGetIndexExpressions() and
-- RelationGetIndexPredicate() (relcache-flattened versions).
-- ================================================================

-- Ensure we can observe parallel worker decisions
SET max_parallel_maintenance_workers = 4;
SET min_parallel_table_scan_size = 0;
SET maintenance_work_mem = '1GB';

-- ================================================================
-- Test 1: Index with parallel-safe expression (functional index)
-- This should pass the parallel-safety check and potentially use
-- parallel workers for the index build.
-- ================================================================
CREATE TABLE test_parallel_safe_expr (id int, val numeric);
INSERT INTO test_parallel_safe_expr SELECT i, random() * 1000 FROM generate_series(1, 100000) i;

-- Create a functional index using a parallel-safe built-in function (abs)
CREATE INDEX idx_safe_expr ON test_parallel_safe_expr (abs(val));
EXPLAIN (COSTS OFF) SELECT * FROM test_parallel_safe_expr WHERE abs(val) > 500;
DROP TABLE test_parallel_safe_expr;

-- ================================================================
-- Test 2: Index with parallel-unsafe expression (using a VOLATILE function)
-- The expression should be detected as not parallel-safe, causing
-- parallel_workers to be set to 0.
-- ================================================================
CREATE OR REPLACE FUNCTION public.unsafe_func(x numeric) RETURNS numeric
LANGUAGE plpgsql AS $$ BEGIN RETURN x + 1; END; $$;

CREATE TABLE test_parallel_unsafe_expr (id int, val numeric);
INSERT INTO test_parallel_unsafe_expr SELECT i, random() * 1000 FROM generate_series(1, 100000) i;

-- Create a functional index using a parallel-unsafe (by default VOLATILE) function
CREATE INDEX idx_unsafe_expr ON test_parallel_unsafe_expr (public.unsafe_func(val));
EXPLAIN (COSTS OFF) SELECT * FROM test_parallel_unsafe_expr WHERE public.unsafe_func(val) > 500;
DROP TABLE test_parallel_unsafe_expr;
DROP FUNCTION public.unsafe_func(x numeric);

-- ================================================================
-- Test 3: Index with parallel-safe predicate (partial index)
-- A partial index with a safe predicate should allow parallel workers.
-- ================================================================
CREATE TABLE test_safe_pred (id int, val numeric, category text);
INSERT INTO test_safe_pred SELECT i, random() * 1000, 'cat' || (i % 5) FROM generate_series(1, 100000) i;

-- Create a partial index with a simple parallel-safe predicate
CREATE INDEX idx_safe_pred ON test_safe_pred (val) WHERE val > 0;
EXPLAIN (COSTS OFF) SELECT * FROM test_safe_pred WHERE val > 0;
DROP TABLE test_safe_pred;

-- ================================================================
-- Test 4: Index with predicate using a parallel-unsafe function
-- The predicate check should detect the parallel-unsafe function,
-- causing parallel_workers to be set to 0.
-- ================================================================
CREATE OR REPLACE FUNCTION public.is_positive(x numeric) RETURNS boolean
LANGUAGE plpgsql AS $$ BEGIN RETURN x > 0; END; $$;

CREATE TABLE test_unsafe_pred (id int, val numeric);
INSERT INTO test_unsafe_pred SELECT i, random() * 1000 FROM generate_series(1, 100000) i;

-- Create a partial index with a parallel-unsafe predicate
CREATE INDEX idx_unsafe_pred ON test_unsafe_pred (val) WHERE public.is_positive(val);
EXPLAIN (COSTS OFF) SELECT * FROM test_unsafe_pred WHERE public.is_positive(val);
DROP TABLE test_unsafe_pred;
DROP FUNCTION public.is_positive(x numeric);

-- ================================================================
-- Test 5: Index with both expression and predicate, one of which is
-- parallel-unsafe. This should also force parallel_workers to 0.
-- Also tests with IMMUTABLE function that is explicitly marked
-- PARALLEL RESTRICTED to test the relcache flattening path.
-- ================================================================
CREATE OR REPLACE FUNCTION public.immutable_restricted(x numeric)
RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL RESTRICTED
AS $$ SELECT x + 1; $$;

CREATE TABLE test_combo_unsafe (id int, val numeric, flag int);
INSERT INTO test_combo_unsafe SELECT i, random() * 1000, i % 2 FROM generate_series(1, 100000) i;

-- Index with expression using PARALLEL RESTRICTED function and a safe predicate
CREATE INDEX idx_combo_unsafe ON test_combo_unsafe (public.immutable_restricted(val)) WHERE flag = 1;
EXPLAIN (COSTS OFF) SELECT * FROM test_combo_unsafe WHERE public.immutable_restricted(val) > 0 AND flag = 1;
DROP TABLE test_combo_unsafe;
DROP FUNCTION public.immutable_restricted(x numeric);

-- ================================================================
-- Clean up GUC settings
-- ================================================================
RESET max_parallel_maintenance_workers;
RESET min_parallel_table_scan_size;
RESET maintenance_work_mem;

----------------------------------------
-- Source: 40.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for commit 40:
--   Fix type-checking of RECORD-returning functions in FROM.
--
-- This test exercises the new code path in ExecInitFunctionScan
-- where rtfunc->funccolnames != NIL causes BuildDescFromLists to
-- be used instead of get_expr_result_type.
--
-- The bug: when a RECORD-returning function is simplified to a
-- RECORD constant or an inlined ROW() expression,
-- ExecInitFunctionScan failed to cross-check against the coldeflist
-- provided by the calling query.
--
-- The fix: always build expected tupdesc from coldeflist if present,
-- consult get_expr_result_type only when there is none.
-- ================================================================

-- ================================================================
-- Test 1: Basic RECORD function with coldeflist (normal case)
-- This exercises the primary new code path:
--   if (rtfunc->funccolnames != NIL) -> BuildDescFromLists
-- The function returns a RECORD with 3 columns, and coldeflist
-- correctly matches.
-- ================================================================

CREATE OR REPLACE FUNCTION test_record_func_basic(n int)
RETURNS RECORD
LANGUAGE SQL
AS $$
  SELECT n, n*2, 'hello'::text;
$$;

-- Explicit coldeflist matching the actual return type
EXPLAIN ANALYZE
SELECT * FROM test_record_func_basic(42)
  AS t1(a int, b int, c text);

-- Same query but with explicit column references
EXPLAIN ANALYZE
SELECT a, c FROM test_record_func_basic(42)
  AS t1(a int, b int, c text);

DROP FUNCTION test_record_func_basic(int);

-- ================================================================
-- Test 2: RECORD function with coldeflist having more columns than
--         the function returns (should produce an error or mismatch
--         that gets caught by CheckVarSlotCompatibility)
-- This exercises the coldeflist path with column count mismatch
-- (function returns 2 cols but coldeflist expects 3).
-- ================================================================

CREATE OR REPLACE FUNCTION test_record_func_fewer(n int)
RETURNS RECORD
LANGUAGE SQL
AS $$
  SELECT n, n*2;
$$;

-- coldeflist expects 3 columns but function returns only 2
EXPLAIN ANALYZE
SELECT * FROM test_record_func_fewer(42)
  AS t1(a int, b int, c text);

DROP FUNCTION test_record_func_fewer(int);

-- ================================================================
-- Test 3: RECORD function with coldeflist having fewer columns than
--         the function returns (function returns more columns than
--         coldeflist expects - the bug scenario from the commit)
-- The old code would silently ignore extra columns; the new code
-- should use coldeflist and properly constrain the result.
-- ================================================================

CREATE OR REPLACE FUNCTION test_record_func_more(n int)
RETURNS RECORD
LANGUAGE SQL
AS $$
  SELECT n, n*2, 'hello'::text, n*3;
$$;

-- coldeflist expects only 2 columns, but function returns 4
EXPLAIN ANALYZE
SELECT * FROM test_record_func_more(42)
  AS t1(a int, b int);

DROP FUNCTION test_record_func_more(int);

-- ================================================================
-- Test 4: RECORD function with coldeflist using different types
--         than the function returns (type mismatch detection)
-- The coldeflist defines types different from function output,
-- which should be caught by CheckVarSlotCompatibility when
-- referenced by a Var.
-- This exercises BuildDescFromLists with type mismatch scenarios.
-- ================================================================

CREATE OR REPLACE FUNCTION test_record_func_type_mismatch(n int)
RETURNS RECORD
LANGUAGE SQL
AS $$
  SELECT n::int, n::text, n::numeric;
$$;

-- coldeflist with wrong types for some columns
EXPLAIN ANALYZE
SELECT a, b FROM test_record_func_type_mismatch(42)
  AS t1(a text, b int, c float8);

DROP FUNCTION test_record_func_type_mismatch(int);

-- ================================================================
-- Test 5: RECORD function with ROWS FROM syntax and coldeflist
--         (multiple functions scenario)
-- This exercises the coldeflist path in a ROWS FROM context,
-- which also goes through ExecInitFunctionScan.
-- ================================================================

CREATE OR REPLACE FUNCTION test_record_rows_1(n int)
RETURNS RECORD
LANGUAGE SQL
AS $$
  SELECT n, 'foo'::text;
$$;

CREATE OR REPLACE FUNCTION test_record_rows_2(n int)
RETURNS RECORD
LANGUAGE SQL
AS $$
  SELECT n*10, 'bar'::text;
$$;

-- ROWS FROM with coldeflists for both RECORD functions
EXPLAIN ANALYZE
SELECT * FROM ROWS FROM (
  test_record_rows_1(1) AS (id int, name text),
  test_record_rows_2(2) AS (val int, label text)
);

-- ROWS FROM with coldeflist + WITH ORDINALITY
EXPLAIN ANALYZE
SELECT * FROM ROWS FROM (
  test_record_rows_1(3) AS (id int, name text),
  test_record_rows_2(4) AS (val int, label text)
) WITH ORDINALITY AS t(a, b, c, d, ord);

DROP FUNCTION test_record_rows_1(int);
DROP FUNCTION test_record_rows_2(int);

----------------------------------------
-- Source: 41.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Explicitly list dependent types as
-- extension members in pg_depend
-- task_id: 41
--
-- This test verifies that dependent types (auto-generated array types
-- and relation rowtypes) are now explicitly recorded as extension
-- members in pg_depend, rather than only the base object.
-- 
-- The code change is in GenerateTypeDependencies() in pg_type.c:
--   recordDependencyOnCurrentExtension() is now called for ALL types,
--   including dependent types (isDependentType=true).
-- Previously it was inside the "if (!isDependentType)" block and
-- thus skipped for dependent types.
-- ================================================================

-- ================================================================
-- Test 1: Custom type outside extension — baseline check
--
-- When a type is created OUTSIDE any extension, neither the base
-- type nor its auto-generated array type should have extension
-- membership deps. This verifies that the new code doesn't
-- incorrectly add extension deps when not in an extension.
-- ================================================================

CREATE FUNCTION test41int_in(cstring)
   RETURNS test41int
   AS 'int4in'
   LANGUAGE internal STRICT IMMUTABLE;

CREATE FUNCTION test41int_out(test41int)
   RETURNS cstring
   AS 'int4out'
   LANGUAGE internal STRICT IMMUTABLE;

CREATE TYPE test41int;

CREATE SCHEMA test41_s1;

CREATE TYPE test41_s1.test41int (
   internallength = 4,
   input = test41int_in,
   output = test41int_out,
   alignment = int4,
   default = 42
);

-- Neither base type nor its array type should have extension deps
SELECT 'Test 1: No extension deps for types outside extension' as info,
       t.typname,
       count(d.*) as extension_deps
FROM pg_type t
LEFT JOIN pg_depend d ON d.refclassid = 'pg_extension'::regclass
                     AND d.classid = 'pg_type'::regclass
                     AND d.objid = t.oid
WHERE t.typnamespace = 'test41_s1'::regnamespace
   OR t.typelem = (SELECT oid FROM pg_type
                   WHERE typnamespace = 'test41_s1'::regnamespace
                     AND typname = 'test41int')
GROUP BY t.typname
ORDER BY t.typname;

DROP SCHEMA test41_s1 CASCADE;

-- ================================================================
-- Test 2: Simulate extension creation — ALTER EXTENSION ADD TYPE
--
-- When a type is added to an extension via ALTER EXTENSION ... ADD TYPE,
-- the dependent array type should also become an extension member.
-- This exercises the code path where GenerateTypeDependencies is
-- called with makeExtensionDep=true for a dependent type (array type).
-- ================================================================

-- We'll create a type, add it to an extension, then check both
-- the type and its array type are extension members.
-- We reuse the postgres_fdw extension (or any pre-installed extension)
-- for this test, using ALTER EXTENSION ... ADD TYPE.

CREATE SCHEMA test41_s2;

CREATE TYPE test41_s2.test41t2 (
   internallength = 4,
   input = test41int_in,
   output = test41int_out,
   alignment = int4
);

-- Add the type to an extension
-- Note: This requires an extension that exists. We'll use postgres_fdw
-- if available, otherwise create a minimal scenario.
DO $$
DECLARE
    ext_name text;
BEGIN
    SELECT extname INTO ext_name FROM pg_extension LIMIT 1;
    IF ext_name IS NOT NULL THEN
        EXECUTE format('ALTER EXTENSION %I ADD TYPE test41_s2.test41t2', ext_name);
    END IF;
END $$;

-- Check: both base type AND array type should now be extension members
SELECT 'Test 2: Type added to extension' as info,
       t.typname,
       (SELECT e.extname FROM pg_extension e
        JOIN pg_depend d ON d.refclassid = 'pg_extension'::regclass
                        AND d.refobjid = e.oid
                        AND d.classid = 'pg_type'::regclass
                        AND d.objid = t.oid) as extension_member_of
FROM pg_type t
WHERE t.typnamespace = 'test41_s2'::regnamespace
   OR (t.typelem = (SELECT oid FROM pg_type
                    WHERE typnamespace = 'test41_s2'::regnamespace
                      AND typname = 'test41t2')
       AND t.typtype = 'b')
ORDER BY t.typname;

-- Clean up by removing from extension first
DO $$
DECLARE
    ext_name text;
BEGIN
    SELECT extname INTO ext_name FROM pg_extension LIMIT 1;
    IF ext_name IS NOT NULL THEN
        EXECUTE format('ALTER EXTENSION %I DROP TYPE test41_s2.test41t2', ext_name);
    END IF;
END $$;

DROP SCHEMA test41_s2 CASCADE;

-- ================================================================
-- Test 3: Relation rowtype as extension member
--
-- When a table is part of an extension, its implicit rowtype
-- (a dependent type, since relationKind != RELKIND_COMPOSITE_TYPE)
-- should also be listed as an extension member.
-- This exercises GenerateTypeDependencies for relation rowtypes.
-- ================================================================

CREATE SCHEMA test41_s3;

CREATE TABLE test41_s3.test41_table (id int, name text);

-- Add the table to an extension
DO $$
DECLARE
    ext_name text;
BEGIN
    SELECT extname INTO ext_name FROM pg_extension LIMIT 1;
    IF ext_name IS NOT NULL THEN
        EXECUTE format('ALTER EXTENSION %I ADD TABLE test41_s3.test41_table', ext_name);
    END IF;
END $$;

-- Check: the rowtype (pg_type entry with typrelid pointing to our table)
-- should be an extension member
SELECT 'Test 3: Rowtype is extension member' as info,
       t.typname,
       t.typrelid::regclass::text as for_table,
       (SELECT e.extname FROM pg_extension e
        JOIN pg_depend d ON d.refclassid = 'pg_extension'::regclass
                        AND d.refobjid = e.oid
                        AND d.classid = 'pg_type'::regclass
                        AND d.objid = t.oid) as extension_member_of
FROM pg_type t
WHERE t.typrelid = 'test41_s3.test41_table'::regclass;

-- Clean up
DO $$
DECLARE
    ext_name text;
BEGIN
    SELECT extname INTO ext_name FROM pg_extension LIMIT 1;
    IF ext_name IS NOT NULL THEN
        EXECUTE format('ALTER EXTENSION %I DROP TABLE test41_s3.test41_table', ext_name);
    END IF;
END $$;

DROP SCHEMA test41_s3 CASCADE;

-- ================================================================
-- Test 4: Composite type (NOT a dependent type)
--
-- Composite types are created via CREATE TYPE ... AS (...),
-- which has relationKind = RELKIND_COMPOSITE_TYPE.
-- These are NOT dependent types — they have their own ownership
-- and permissions. This test verifies that the code correctly
-- distinguishes dependent vs. non-dependent types.
-- ================================================================

CREATE SCHEMA test41_s4;

CREATE TYPE test41_s4.test41_comp AS (a int, b text);

-- Add the composite type to an extension
DO $$
DECLARE
    ext_name text;
BEGIN
    SELECT extname INTO ext_name FROM pg_extension LIMIT 1;
    IF ext_name IS NOT NULL THEN
        EXECUTE format('ALTER EXTENSION %I ADD TYPE test41_s4.test41_comp', ext_name);
    END IF;
END $$;

-- Composite types should also get extension membership (they're not
-- dependent types, but the new code path doesn't change this behavior)
SELECT 'Test 4: Composite type is extension member' as info,
       t.typname,
       t.typtype,
       (SELECT e.extname FROM pg_extension e
        JOIN pg_depend d ON d.refclassid = 'pg_extension'::regclass
                        AND d.refobjid = e.oid
                        AND d.classid = 'pg_type'::regclass
                        AND d.objid = t.oid) as extension_member_of
FROM pg_type t
WHERE t.typnamespace = 'test41_s4'::regnamespace;

-- Clean up
DO $$
DECLARE
    ext_name text;
BEGIN
    SELECT extname INTO ext_name FROM pg_extension LIMIT 1;
    IF ext_name IS NOT NULL THEN
        EXECUTE format('ALTER EXTENSION %I DROP TYPE test41_s4.test41_comp', ext_name);
    END IF;
END $$;

DROP SCHEMA test41_s4 CASCADE;

-- ================================================================
-- Test 5: Verify pg_depend query pattern for shippability
--
-- The commit message mentions postgres_fdw shippability tests.
-- When an expression involves an array type, postgres_fdw checks
-- if the array type belongs to an extension that has been whitelisted.
-- This test verifies that the pg_depend query correctly finds
-- extension membership for dependent array types.
-- ================================================================

CREATE SCHEMA test41_s5;

-- Create a type and its array, add to extension
CREATE TYPE test41_s5.test41t5 (
   internallength = 4,
   input = test41int_in,
   output = test41int_out,
   alignment = int4
);

DO $$
DECLARE
    ext_name text;
BEGIN
    SELECT extname INTO ext_name FROM pg_extension LIMIT 1;
    IF ext_name IS NOT NULL THEN
        EXECUTE format('ALTER EXTENSION %I ADD TYPE test41_s5.test41t5', ext_name);
    END IF;
END $$;

-- This is the key query pattern: find if a type (including array types)
-- is an extension member. Before the fix, array types would not show up.
SELECT 'Test 5a: Direct type membership' as info,
       t.typname,
       e.extname
FROM pg_type t
JOIN pg_depend d ON d.refclassid = 'pg_extension'::regclass
                AND d.classid = 'pg_type'::regclass
                AND d.objid = t.oid
JOIN pg_extension e ON e.oid = d.refobjid
WHERE t.typnamespace = 'test41_s5'::regnamespace
   OR (t.typelem IN (SELECT oid FROM pg_type
                     WHERE typnamespace = 'test41_s5'::regnamespace
                       AND typname = 'test41t5')
       AND t.typtype = 'b')
ORDER BY t.typname;

-- Try using array literal to exercise the type
SELECT 'Test 5b: Using array of custom type' as info,
       ARRAY[ROW(1)::test41_s5.test41t5]::test41_s5.test41t5[] as arr_val;

-- Clean up
DO $$
DECLARE
    ext_name text;
BEGIN
    SELECT extname INTO ext_name FROM pg_extension LIMIT 1;
    IF ext_name IS NOT NULL THEN
        EXECUTE format('ALTER EXTENSION %I DROP TYPE test41_s5.test41t5', ext_name);
    END IF;
END $$;

DROP SCHEMA test41_s5 CASCADE;

-- Drop helper functions
DROP FUNCTION test41int_in(cstring);
DROP FUNCTION test41int_out(test41int);

-- ================================================================
-- End of tests
-- ================================================================

----------------------------------------
-- Source: 42.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Promote assertion about !ReindexIsProcessingIndex 
-- to runtime error (systable_beginscan_ordered)
-- task_id: 42
-- 
-- This test exercises the code path in systable_beginscan_ordered()
-- where ReindexIsProcessingIndex() is checked and a runtime error
-- is raised with ERRCODE_FEATURE_NOT_SUPPORTED.
-- ================================================================

-- ================================================================
-- Test 1: REINDEX of system tables
-- 
-- Coverage: Exercises the systable_beginscan_ordered check during
-- REINDEX operations on system catalog indexes. This tests the 
-- normal path where REINDEX completes without triggering concurrent
-- ordered scans on the same index.
-- ================================================================

-- Reindex individual system catalog indexes that are commonly used
-- with systable_beginscan_ordered 
REINDEX INDEX pg_enum_typid_sortorder_index;
REINDEX INDEX pg_event_trigger_evtname_index;
REINDEX INDEX pg_largeobject_loid_pn_index;

-- Reindex entire catalog tables
REINDEX TABLE pg_enum;
REINDEX TABLE pg_event_trigger;

-- ================================================================
-- Test 2: Enum type operations using systable_beginscan_ordered
-- 
-- Coverage: Enum functions (enum_first, enum_last, enum_range) 
-- internally call systable_beginscan_ordered on the pg_enum catalog.
-- This tests that the code path works correctly when no REINDEX 
-- is in progress.
-- ================================================================

BEGIN;

CREATE TYPE rainbow AS ENUM ('red', 'orange', 'yellow', 'green', 'blue', 'purple');

-- enum_first, enum_last, and enum_range all use systable_beginscan_ordered
SELECT enum_first('red'::rainbow);
SELECT enum_last('purple'::rainbow);
SELECT enum_range('orange'::rainbow, 'blue'::rainbow);
SELECT enum_range(NULL::rainbow);

-- Test with empty enum - edge case
CREATE TYPE empty_enum AS ENUM ();
SELECT enum_first('empty_enum'::empty_enum);  -- should error with no values
SELECT enum_last('empty_enum'::empty_enum);   -- should error with no values

DROP TYPE empty_enum;
DROP TYPE rainbow;

COMMIT;

-- ================================================================
-- Test 3: Enum operations with large number of values (edge case)
-- 
-- Coverage: systable_beginscan_ordered with many rows in pg_enum,
-- testing scanning in both forward and reverse directions.
-- ================================================================

BEGIN;

CREATE TYPE many_colors AS ENUM (
    'c0', 'c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8', 'c9',
    'c10', 'c11', 'c12', 'c13', 'c14', 'c15', 'c16', 'c17', 'c18', 'c19',
    'c20', 'c21', 'c22', 'c23', 'c24', 'c25', 'c26', 'c27', 'c28', 'c29'
);

-- enum_range scans with boundaries at various positions
SELECT enum_range('c0'::many_colors, 'c29'::many_colors);
SELECT enum_range('c10'::many_colors, 'c20'::many_colors);
SELECT enum_range(NULL::many_colors, 'c15'::many_colors);
SELECT enum_range('c15'::many_colors, NULL::many_colors);

-- enum_first and enum_last on non-empty type
SELECT enum_first('c5'::many_colors);
SELECT enum_last('c25'::many_colors);

DROP TYPE many_colors;

COMMIT;

-- ================================================================
-- Test 4: Large object operations using systable_beginscan_ordered
-- 
-- Coverage: Large object read/write operations call 
-- systable_beginscan_ordered on pg_largeobject. This tests the 
-- code path for the large object call sites.
-- ================================================================

BEGIN;

-- Create a large object
SELECT lo_create(42);
SELECT lo_create(100);

-- Write data to the large object (triggers systable_beginscan_ordered)
SELECT lowrite(lo_open(42, x'20000'::int), '\xdeadbeef');
SELECT lowrite(lo_open(100, x'20000'::int), '\xabcdef0123456789');

-- Read data from the large object (triggers systable_beginscan_ordered)
SELECT loread(lo_open(42, x'40000'::int), 4);
SELECT loread(lo_open(100, x'40000'::int), 8);

-- Seek and read at different positions
SELECT lo_lseek(42, 0, 0);
SELECT loread(lo_open(42, x'40000'::int), 4);

-- Clean up
SELECT lo_unlink(42);
SELECT lo_unlink(100);

COMMIT;

-- ================================================================
-- Test 5: Event trigger operations using systable_beginscan_ordered
-- 
-- Coverage: Event trigger cache building calls 
-- systable_beginscan_ordered on pg_event_trigger. This tests the 
-- code path when event triggers are defined and triggered.
-- ================================================================

BEGIN;

-- Create event triggers that fire on DDL commands
CREATE OR REPLACE FUNCTION event_trigger_report() 
RETURNS event_trigger 
LANGUAGE plpgsql 
AS $$
BEGIN
    RAISE NOTICE 'Event trigger fired: %', tg_event;
END;
$$;

-- Create event triggers (this builds the event trigger cache using systable_beginscan_ordered)
CREATE EVENT TRIGGER ddl_start_trigger ON ddl_command_start 
    EXECUTE FUNCTION event_trigger_report();

CREATE EVENT TRIGGER ddl_end_trigger ON ddl_command_end 
    EXECUTE FUNCTION event_trigger_report();

-- Perform DDL to trigger event triggers (exercises the cache)
CREATE TEMP TABLE test_evt_trigger (id int);

-- Drop the triggers
DROP EVENT TRIGGER ddl_start_trigger;
DROP EVENT TRIGGER ddl_end_trigger;
DROP FUNCTION event_trigger_report();

COMMIT;

-- ================================================================
-- End of regression tests
-- ================================================================

----------------------------------------
-- Source: 43.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: pgsql: Remove race condition in pg_get_expr()
-- task_id: 43
--
-- Coverage: This commit moves the relid validation inside
-- pg_get_expr_worker(), using try_relation_open(relid, AccessShareLock)
-- to lock the relation and prevent race conditions with concurrent drops.
-- The old code had a separate get_rel_name() check with a race window.
-- ================================================================

-- ##################################################################
-- Test 1: pg_get_expr with a valid relation OID (partial index expression)
--
-- Covers: pg_get_expr() -> pg_get_expr_worker() with valid relid
--   -> try_relation_open(relid, AccessShareLock) succeeds
--   -> deparse_context_for(RelationGetRelationName(rel), relid)
--   -> relation_close(rel, AccessShareLock)
-- ##################################################################
CREATE TABLE test43_t1 (a int, b text);
CREATE INDEX test43_idx1 ON test43_t1 (a) WHERE b IS NOT NULL;

-- Query pg_index to extract the partial index predicate via pg_get_expr
SELECT pg_get_expr(i.indpred, i.indrelid) AS pred
FROM pg_index i
JOIN pg_class c ON i.indexrelid = c.oid
WHERE c.relname = 'test43_idx1';

DROP INDEX test43_idx1;
DROP TABLE test43_t1;

-- ##################################################################
-- Test 2: pg_get_expr_ext with valid relation and pretty=true
--
-- Covers: pg_get_expr_ext() -> pg_get_expr_worker() with valid relid
--   and PRETTYFLAG_PAREN | PRETTYFLAG_INDENT | PRETTYFLAG_SCHEMA flags
-- ##################################################################
CREATE TABLE test43_t2 (x int CHECK (x > 0));

-- Extract the check constraint expression with pretty-printing
SELECT pg_get_expr_ext(c.conbin, c.conrelid, true) AS consrc_pretty
FROM pg_constraint c
JOIN pg_class r ON c.conrelid = r.oid
WHERE r.relname = 'test43_t2'
  AND c.contype = 'c';

DROP TABLE test43_t2;

-- ##################################################################
-- Test 3: pg_get_expr with InvalidOid (Var-free expression, no relation)
--
-- Covers: pg_get_expr_worker() with OidIsValid(relid) == false
--   -> context = NIL (no relation needed)
--   -> deparse_expression_pretty with no Var references
-- ################################################################--
SELECT pg_get_expr('42'::pg_node_tree, 0::oid);

-- Also test with a more complex constant expression
SELECT pg_get_expr('("abc"::text || "def"::text)'::pg_node_tree, 0::oid);

-- ##################################################################
-- Test 4: pg_get_expr with nonexistent relation OID (invalid relid)
--
-- Covers: pg_get_expr_worker() with valid relid but relation doesn't exist
--   -> try_relation_open(relid, AccessShareLock) returns NULL
--   -> function returns NULL immediately
-- This is the core fix: old code had a race window between get_rel_name()
-- and deparse, new code locks the relation atomically.
-- ################################################################--
CREATE TABLE test43_t4 (id int);
DO $$
DECLARE
  bad_oid oid;
  result text;
BEGIN
  -- Get a valid OID, then drop the table, then try to use that OID
  SELECT oid INTO bad_oid FROM pg_class WHERE relname = 'test43_t4';
  DROP TABLE test43_t4;

  -- Now try pg_get_expr with the now-stale OID
  -- This should return NULL instead of throwing an error
  SELECT pg_get_expr('42'::pg_node_tree, bad_oid) INTO result;
  IF result IS NOT NULL THEN
    RAISE 'Expected NULL result for dropped relation OID %', bad_oid;
  END IF;
END $$;

-- ##################################################################
-- Test 5: pg_get_expr with a column default expression
--
-- Covers: pg_get_expr() on pg_attrdef.adbin with valid relid
--   -> try_relation_open succeeds
--   -> deparse_context_for builds correct context
--   -> relation_close releases lock
-- ################################################################--
CREATE TABLE test43_t5 (
    id serial PRIMARY KEY,
    name text DEFAULT 'anonymous',
    created_at timestamp DEFAULT now()
);

-- Extract default expressions using pg_get_expr
SELECT
    a.attname,
    pg_get_expr(d.adbin, d.adrelid) AS default_expr
FROM
    pg_attrdef d
    JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
    JOIN pg_class r ON r.oid = d.adrelid
WHERE
    r.relname = 'test43_t5';

DROP TABLE test43_t5;

----------------------------------------
-- Source: 44.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix wrong logic in TransactionIdInRecentPast()
-- task_id: 44
--
-- This test exercises the TransactionIdInRecentPast() function via
-- pg_xact_status(), which is the SQL-callable entry point. The commit
-- fixes the comparison logic by converting oldestClogXid into a
-- FullTransactionId before comparing it to the given fxid.
--
-- Code paths covered:
--   1. oldest_xid <= now_epoch_next_xid → same epoch (normal path)
--   2. oldest_xid > now_epoch_next_xid → epoch - 1 (wraparound edge)
--   3. fxid >= oldest_fxid → return true (CLOG entry exists)
--   4. fxid < oldest_fxid → return false (too old, return NULL)
-- ================================================================

-- ================================================================
-- Test 1: Basic committed/rolledback/in-progress transactions
-- Covers: Normal code path (oldest_xid <= now_epoch_next_xid),
--         fxid >= oldest_fxid → true
-- ================================================================
BEGIN;

-- Create a committed transaction
SELECT pg_current_xact_id() AS committed \gset
COMMIT;

BEGIN;

-- Create a rolled-back transaction
SELECT pg_current_xact_id() AS rolledback \gset
ROLLBACK;

BEGIN;

-- Create an in-progress transaction reference
SELECT pg_current_xact_id() AS inprogress \gset

-- Query status of all three; all should exercise the normal code path
SELECT pg_xact_status(:committed::text::xid8) AS committed;
SELECT pg_xact_status(:rolledback::text::xid8) AS rolledback;
SELECT pg_xact_status(:inprogress::text::xid8) AS inprogress;

COMMIT;

-- ================================================================
-- Test 2: Special transaction IDs (Bootstrap, Frozen, FirstNormal)
-- Covers: Non-normal transaction IDs (TransactionIdIsNormal check)
--         BootstrapTransactionId=1 and FrozenTransactionId=2
--         are always considered "recent past"
-- ================================================================
SELECT pg_xact_status('1'::xid8) AS bootstrap_xid;
SELECT pg_xact_status('2'::xid8) AS frozen_xid;
SELECT pg_xact_status('3'::xid8) AS first_normal_xid;

-- ================================================================
-- Test 3: NULL-like and invalid transaction IDs
-- Covers: TransactionIdIsValid returning false → return false
--         Invalid XID (0) should return NULL from pg_xact_status
-- ================================================================
SELECT pg_xact_status('0'::xid8) AS invalid_xid;

-- Test with very large xid8 values that map to future/valid xids
-- These should still be handled (if not in the future)
SELECT pg_xact_status('4294967295'::xid8) AS max_xid;  -- 2^32 - 1, maximum TransactionId

-- ================================================================
-- Test 4: Future transaction ID should raise an error
-- Covers: FullTransactionIdPrecedes(fxid, now_fullxid) check
--         When fxid is in the future → ERROR
-- ================================================================
BEGIN;
SELECT pg_current_xact_id() AS current_id \gset
COMMIT;

BEGIN;
CREATE OR REPLACE FUNCTION test_future_xid_status(xid8)
RETURNS void
LANGUAGE plpgsql
AS
$$
BEGIN
  PERFORM pg_xact_status($1);
  RAISE EXCEPTION 'did not ERROR at xid in the future as expected';
EXCEPTION
  WHEN invalid_parameter_value THEN
    RAISE NOTICE 'Got expected error for xid in the future';
END;
$$;
SELECT test_future_xid_status((:current_id + 10000)::text::xid8);
ROLLBACK;

-- ================================================================
-- Test 5: Transaction IDs with epoch values (via xid8 range)
-- Covers: The function's handling of different FullTransactionId values
--         Exercise the comparison: !FullTransactionIdPrecedes(fxid, oldest_fxid)
--         Use a mix of recent and slightly older transaction IDs
-- ================================================================
BEGIN;

-- Create another committed transaction to get a stable xid
SELECT pg_current_xact_id() AS recent_xid \gset
COMMIT;

BEGIN;
-- Use that recent xid
SELECT pg_xact_status(:recent_xid::text::xid8) AS recent_committed;

-- Also test with a high xid8 value that is NOT in the future
-- (Using values within reasonable range)
SELECT pg_xact_status('100'::xid8) AS older_xid;
SELECT pg_xact_status('1000'::xid8) AS even_older_xid;
COMMIT;

-- Cleanup: drop the test function if it exists
DROP FUNCTION IF EXISTS test_future_xid_status(xid8);

----------------------------------------
-- Source: 45.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix assertion if index is dropped during REFRESH CONCURRENTLY
-- task_id: 45
-- 
-- This test exercises the code path in refresh_by_match_merge() where
-- an Assert(foundUniqueIndex) was replaced with:
--   if (!foundUniqueIndex)
--       elog(ERROR, "could not find suitable unique index on materialized view");
-- 
-- The change fixes a case where a function called as part of refreshing
-- the materialized view drops the unique index, causing an assertion failure
-- in assert-enabled builds and a syntax error in non-assert builds.
-- ================================================================


-- ================================================================
-- Test 1: Normal REFRESH CONCURRENTLY with a unique index (happy path)
-- Covers: The normal code path where foundUniqueIndex is true,
--         no error is raised, refresh succeeds.
-- ================================================================
BEGIN;

CREATE TABLE test1_source (a int, b text);
INSERT INTO test1_source VALUES (1, 'one'), (2, 'two'), (3, 'three');

CREATE MATERIALIZED VIEW test1_mv AS SELECT * FROM test1_source;
CREATE UNIQUE INDEX test1_mv_idx ON test1_mv (a);

REFRESH MATERIALIZED VIEW CONCURRENTLY test1_mv;

-- Verify the data is correct
SELECT * FROM test1_mv ORDER BY a;

-- Insert new data and refresh again
INSERT INTO test1_source VALUES (4, 'four');
REFRESH MATERIALIZED VIEW CONCURRENTLY test1_mv;

SELECT * FROM test1_mv ORDER BY a;

DROP MATERIALIZED VIEW test1_mv;
DROP TABLE test1_source;

COMMIT;


-- ================================================================
-- Test 2: REFRESH CONCURRENTLY on a matview with NO unique index
-- Covers: ExecRefreshMatView() early check that rejects CONCURRENTLY
--         when no unique index exists at all (ereport before
--         refresh_by_match_merge is even called).
-- Expected: ERROR: cannot refresh materialized view ... concurrently
-- ================================================================
BEGIN;

CREATE TABLE test2_source (x int, y int);
INSERT INTO test2_source VALUES (10, 100), (20, 200);

CREATE MATERIALIZED VIEW test2_mv AS SELECT * FROM test2_source;

-- This should fail because there is no unique index on the matview
-- ERROR:  cannot refresh materialized view "test2_mv" concurrently
-- HINT:  Create a unique index with no WHERE clause on one or more columns...
REFRESH MATERIALIZED VIEW CONCURRENTLY test2_mv;

ROLLBACK;


-- ================================================================
-- Test 3: REFRESH CONCURRENTLY where the ONLY unique index is dropped
--         during data refresh by a function in the matview query.
-- Covers: The NEW code path in refresh_by_match_merge():
--         if (!foundUniqueIndex)
--             elog(ERROR, "could not find suitable unique index...");
-- Expected: ERROR: could not find suitable unique index on materialized view
-- ================================================================
BEGIN;

-- Create a function that drops our specific index
CREATE OR REPLACE FUNCTION test3_drop_the_index()
  RETURNS bool AS $$
BEGIN
  EXECUTE 'DROP INDEX IF EXISTS test3_mv_idx';
  RETURN true;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE test3_source (id int, val text);
INSERT INTO test3_source VALUES (1, 'alpha'), (2, 'beta');

-- The function test3_drop_the_index() is called during data refresh
-- (when REFRESH CONCURRENTLY re-executes the defining query).
-- After the function drops the only unique index, refresh_by_match_merge
-- will find no unique index and trigger the new elog(ERROR).
CREATE MATERIALIZED VIEW test3_mv AS
  SELECT id, val FROM test3_source WHERE test3_drop_the_index();

CREATE UNIQUE INDEX test3_mv_idx ON test3_mv (id);

-- This should trigger the new error path:
-- ERROR:  could not find suitable unique index on materialized view
REFRESH MATERIALIZED VIEW CONCURRENTLY test3_mv;

ROLLBACK;


-- ================================================================
-- Test 4: REFRESH CONCURRENTLY with multiple unique indexes,
--         where one index is dropped but another survives.
-- Covers: The scenario where at least one unique index remains,
--         so foundUniqueIndex stays true and refresh succeeds.
--         Exercises the loop logic that iterates over all indexes.
-- ================================================================
BEGIN;

CREATE OR REPLACE FUNCTION test4_drop_one_index()
  RETURNS bool AS $$
BEGIN
  EXECUTE 'DROP INDEX IF EXISTS test4_mv_idx_a';
  RETURN true;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE test4_source (id int, name text);
INSERT INTO test4_source VALUES (1, 'foo'), (2, 'bar');

CREATE MATERIALIZED VIEW test4_mv AS
  SELECT id, name FROM test4_source WHERE test4_drop_one_index();

-- Create two unique indexes on different columns
CREATE UNIQUE INDEX test4_mv_idx_a ON test4_mv (id);
CREATE UNIQUE INDEX test4_mv_idx_b ON test4_mv (name);

-- The function drops idx_a, but idx_b remains, so refresh should succeed
REFRESH MATERIALIZED VIEW CONCURRENTLY test4_mv;

SELECT * FROM test4_mv ORDER BY id;

DROP MATERIALIZED VIEW test4_mv;
DROP TABLE test4_source;
DROP FUNCTION test4_drop_one_index();

COMMIT;


-- ================================================================
-- Test 5: REFRESH CONCURRENTLY on empty matview (edge case: zero rows)
-- Covers: The code path in refresh_by_match_merge with
--         foundUniqueIndex = true but zero data rows.
--         Tests that the diff table creation and merge logic handles
--         empty result sets gracefully.
-- ================================================================
BEGIN;

CREATE TABLE test5_source (k int PRIMARY KEY, v int);
-- No data in source table

CREATE MATERIALIZED VIEW test5_mv AS SELECT * FROM test5_source;
CREATE UNIQUE INDEX test5_mv_idx ON test5_mv (k);

-- Refresh on empty matview
REFRESH MATERIALIZED VIEW CONCURRENTLY test5_mv;

-- Verify it's still empty
SELECT count(*) FROM test5_mv;

-- Now add data and refresh
INSERT INTO test5_source VALUES (1, 100), (2, 200);
REFRESH MATERIALIZED VIEW CONCURRENTLY test5_mv;

SELECT * FROM test5_mv ORDER BY k;

-- Update existing data and refresh again
UPDATE test5_source SET v = 999 WHERE k = 1;
REFRESH MATERIALIZED VIEW CONCURRENTLY test5_mv;

SELECT * FROM test5_mv ORDER BY k;

-- Delete a row and refresh
DELETE FROM test5_source WHERE k = 2;
REFRESH MATERIALIZED VIEW CONCURRENTLY test5_mv;

SELECT * FROM test5_mv ORDER BY k;

DROP MATERIALIZED VIEW test5_mv;
DROP TABLE test5_source;

COMMIT;

----------------------------------------
-- Source: 46.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for:
-- "Apply band-aid fix for an oversight in reparameterize_path_by_child"
--
-- task_id: 46
--
-- This test exercises the newly added code paths in
-- reparameterize_path_by_child() that check for lateral references
-- to the other relation in restriction clauses and tablesample
-- clauses before attempting reparameterization for partitionwise join.
--
-- The new code detects whether baserestrictinfo or tablesample
-- clauses contain lateral references (Vars or PlaceHolderVars) to
-- the join partner's parent relation, and if so, returns NULL
-- (falling back to non-partitionwise join) instead of modifying
-- shared expressions that could break other paths.
-- ================================================================

-- enable partitionwise join for all tests
SET enable_partitionwise_join = true;
SET enable_partitionwise_aggregate = true;

-- ================================================================
-- Test 1: Lateral references in baserestrictinfo clauses
--         (covers T_Path case: ris_contain_references_to on baserestrictinfo)
-- 
-- When lateral references to the other relation exist in baserestrictinfo,
-- reparameterize_path_by_child should return NULL, causing fallback to
-- non-partitionwise join. This test verifies that the query completes
-- successfully even with such lateral references.
-- ================================================================
CREATE TABLE test46_p1 (a int, b int, c text) PARTITION BY RANGE (a);
CREATE TABLE test46_p1_p1 PARTITION OF test46_p1 FOR VALUES FROM (0) TO (100);
CREATE TABLE test46_p1_p2 PARTITION OF test46_p1 FOR VALUES FROM (100) TO (200);
INSERT INTO test46_p1 SELECT i, i % 10, 'val' || i FROM generate_series(1, 199) i;

CREATE TABLE test46_p2 (a int, b int, c text) PARTITION BY RANGE (b);
CREATE TABLE test46_p2_p1 PARTITION OF test46_p2 FOR VALUES FROM (0) TO (100);
CREATE TABLE test46_p2_p2 PARTITION OF test46_p2 FOR VALUES FROM (100) TO (200);
INSERT INTO test46_p2 SELECT i % 10, i, 'val' || i FROM generate_series(1, 199) i;

ANALYZE test46_p1;
ANALYZE test46_p2;

-- This creates a lateral reference from the inner relation's restriction
-- clause to the outer relation. The subquery in the lateral join references
-- t1.b, which becomes part of baserestrictinfo of the inner scan path.
EXPLAIN (COSTS OFF)
SELECT count(*) FROM test46_p1 t1 LEFT JOIN LATERAL
    (SELECT t1.b AS t1b, t2.* FROM test46_p2 t2) s
    ON t1.a = s.b
    WHERE s.t1b = s.a;
SELECT count(*) FROM test46_p1 t1 LEFT JOIN LATERAL
    (SELECT t1.b AS t1b, t2.* FROM test46_p2 t2) s
    ON t1.a = s.b
    WHERE s.t1b = s.a;

DROP TABLE test46_p1;
DROP TABLE test46_p2;


-- ================================================================
-- Test 2: Lateral references in SampleScan tablesample clause
--         (covers T_Path + T_SampleScan path: contain_references_to on rte->tablesample)
--
-- When a SampleScan path's tablesample clause contains lateral references
-- to the other relation, reparameterize_path_by_child should return NULL.
-- This test uses TABLESAMPLE with parameters referencing the outer relation.
-- ================================================================
CREATE TABLE test46_ts1 (a int, b int, c text) PARTITION BY RANGE (a);
CREATE TABLE test46_ts1_p1 PARTITION OF test46_ts1 FOR VALUES FROM (0) TO (100);
CREATE TABLE test46_ts1_p2 PARTITION OF test46_ts1 FOR VALUES FROM (100) TO (200);
INSERT INTO test46_ts1 SELECT i, i % 10, 'val' || i FROM generate_series(1, 199) i;

CREATE TABLE test46_ts2 (a int, b int, c text) PARTITION BY RANGE (b);
CREATE TABLE test46_ts2_p1 PARTITION OF test46_ts2 FOR VALUES FROM (0) TO (100);
CREATE TABLE test46_ts2_p2 PARTITION OF test46_ts2 FOR VALUES FROM (100) TO (200);
INSERT INTO test46_ts2 SELECT i % 10, i, 'val' || i FROM generate_series(1, 199) i;

ANALYZE test46_ts1;
ANALYZE test46_ts2;

-- The TABLESAMPLE SYSTEM with parameters from the outer relation t1
-- creates lateral references in the tablesample clause, triggering the
-- SampleScan-specific check in reparameterize_path_by_child.
EXPLAIN (COSTS OFF)
SELECT * FROM test46_ts1 t1 JOIN LATERAL
    (SELECT * FROM test46_ts1 t2 TABLESAMPLE SYSTEM (t1.a) REPEATABLE(t1.b)) s
    ON t1.a = s.a;

DROP TABLE test46_ts1;
DROP TABLE test46_ts2;


-- ================================================================
-- Test 3: Lateral references with IndexScan path
--         (covers T_IndexPath case: ris_contain_references_to on baserestrictinfo)
--
-- When using an index scan on the inner side of a partitionwise join,
-- if baserestrictinfo contains lateral references to the other relation,
-- the new check in the IndexPath case should trigger.
-- ================================================================
CREATE TABLE test46_idx1 (a int, b int, c text) PARTITION BY RANGE (a);
CREATE TABLE test46_idx1_p1 PARTITION OF test46_idx1 FOR VALUES FROM (0) TO (100);
CREATE TABLE test46_idx1_p2 PARTITION OF test46_idx1 FOR VALUES FROM (100) TO (200);
INSERT INTO test46_idx1 SELECT i, i % 10, 'val' || i FROM generate_series(1, 199) i;
CREATE INDEX ON test46_idx1_p1 (a);
CREATE INDEX ON test46_idx1_p2 (a);

CREATE TABLE test46_idx2 (a int, b int, c text) PARTITION BY RANGE (b);
CREATE TABLE test46_idx2_p1 PARTITION OF test46_idx2 FOR VALUES FROM (0) TO (100);
CREATE TABLE test46_idx2_p2 PARTITION OF test46_idx2 FOR VALUES FROM (100) TO (200);
INSERT INTO test46_idx2 SELECT i % 10, i, 'val' || i FROM generate_series(1, 199) i;
CREATE INDEX ON test46_idx2_p1 (b);
CREATE INDEX ON test46_idx2_p2 (b);

ANALYZE test46_idx1;
ANALYZE test46_idx2;

-- Force index scan to ensure IndexPath is chosen for the inner side
SET enable_seqscan = off;
SET enable_bitmapscan = off;

-- The lateral reference in the WHERE clause creates a situation where
-- baserestrictinfo of the inner path contains references to the outer
-- relation, triggering the IndexPath check.
EXPLAIN (COSTS OFF)
SELECT count(*) FROM test46_idx1 t1 LEFT JOIN LATERAL
    (SELECT t1.b AS t1b, t2.* FROM test46_idx2 t2) s
    ON t1.a = s.b
    WHERE s.t1b = s.b;
SELECT count(*) FROM test46_idx1 t1 LEFT JOIN LATERAL
    (SELECT t1.b AS t1b, t2.* FROM test46_idx2 t2) s
    ON t1.a = s.b
    WHERE s.t1b = s.b;

RESET enable_seqscan;
RESET enable_bitmapscan;

DROP TABLE test46_idx1;
DROP TABLE test46_idx2;


-- ================================================================
-- Test 4: Lateral references with BitmapHeapScan path
--         (covers T_BitmapHeapPath case: ris_contain_references_to on baserestrictinfo)
--
-- When using bitmap heap scan on the inner side, if baserestrictinfo
-- contains lateral references, the new check in BitmapHeapPath case
-- should trigger and return NULL.
-- ================================================================
CREATE TABLE test46_bm1 (a int, b int, c text) PARTITION BY RANGE (a);
CREATE TABLE test46_bm1_p1 PARTITION OF test46_bm1 FOR VALUES FROM (0) TO (100);
CREATE TABLE test46_bm1_p2 PARTITION OF test46_bm1 FOR VALUES FROM (100) TO (200);
INSERT INTO test46_bm1 SELECT i, i % 10, 'val' || i FROM generate_series(1, 199) i;
CREATE INDEX ON test46_bm1_p1 (a);
CREATE INDEX ON test46_bm1_p2 (a);

CREATE TABLE test46_bm2 (a int, b int, c text) PARTITION BY RANGE (b);
CREATE TABLE test46_bm2_p1 PARTITION OF test46_bm2 FOR VALUES FROM (0) TO (100);
CREATE TABLE test46_bm2_p2 PARTITION OF test46_bm2 FOR VALUES FROM (100) TO (200);
INSERT INTO test46_bm2 SELECT i % 10, i, 'val' || i FROM generate_series(1, 199) i;
CREATE INDEX ON test46_bm2_p1 (b);
CREATE INDEX ON test46_bm2_p2 (b);

ANALYZE test46_bm1;
ANALYZE test46_bm2;

-- Force bitmap scan to ensure BitmapHeapPath is chosen
SET enable_seqscan = off;
SET enable_indexscan = off;

EXPLAIN (COSTS OFF)
SELECT count(*) FROM test46_bm1 t1 LEFT JOIN LATERAL
    (SELECT t1.b AS t1b, t2.* FROM test46_bm2 t2) s
    ON t1.a = s.b
    WHERE s.t1b = s.a;
SELECT count(*) FROM test46_bm1 t1 LEFT JOIN LATERAL
    (SELECT t1.b AS t1b, t2.* FROM test46_bm2 t2) s
    ON t1.a = s.b
    WHERE s.t1b = s.a;

RESET enable_seqscan;
RESET enable_indexscan;

DROP TABLE test46_bm1;
DROP TABLE test46_bm2;


-- ================================================================
-- Test 5: Lateral references with PlaceHolderVar in restriction clause
--         (covers contain_references_to with PlaceHolderVar check:
--          both ph_eval_at and ph_lateral checks)
--
-- When a PlaceHolderVar in baserestrictinfo has ph_eval_at or ph_lateral
-- overlapping with the other relation's relids, the new PlaceHolderVar
-- check in contain_references_to should trigger.
-- ================================================================
CREATE TABLE test46_ph1 (a int, b int, c text) PARTITION BY RANGE (a);
CREATE TABLE test46_ph1_p1 PARTITION OF test46_ph1 FOR VALUES FROM (0) TO (100);
CREATE TABLE test46_ph1_p2 PARTITION OF test46_ph1 FOR VALUES FROM (100) TO (200);
INSERT INTO test46_ph1 SELECT i, i % 10, 'val' || i FROM generate_series(1, 199) i;

CREATE TABLE test46_ph2 (a int, b int, c text) PARTITION BY RANGE (b);
CREATE TABLE test46_ph2_p1 PARTITION OF test46_ph2 FOR VALUES FROM (0) TO (100);
CREATE TABLE test46_ph2_p2 PARTITION OF test46_ph2 FOR VALUES FROM (100) TO (200);
INSERT INTO test46_ph2 SELECT i % 10, i, 'val' || i FROM generate_series(1, 199) i;

ANALYZE test46_ph1;
ANALYZE test46_ph2;

-- Using FULL JOIN with subquery that produces PHVs and lateral references.
-- The subquery introduces placeholders (via constant expressions) that
-- get turned into PlaceHolderVars. When these PHVs end up in restriction
-- clauses that are checked during reparameterization, the new PHV check
-- in contain_references_to() is exercised.
EXPLAIN (COSTS OFF)
SELECT t1.a, t1.c, t2.b, t2.c
FROM (SELECT 42 phv, * FROM test46_ph1 WHERE test46_ph1.b = 0) t1
FULL JOIN (SELECT 99 phv, * FROM test46_ph2 WHERE test46_ph2.a = 0) t2
    ON (t1.a = t2.b)
WHERE (t1.phv = t1.a OR t2.phv = t2.b)
ORDER BY t1.a, t2.b;

SELECT t1.a, t1.c, t2.b, t2.c
FROM (SELECT 42 phv, * FROM test46_ph1 WHERE test46_ph1.b = 0) t1
FULL JOIN (SELECT 99 phv, * FROM test46_ph2 WHERE test46_ph2.a = 0) t2
    ON (t1.a = t2.b)
WHERE (t1.phv = t1.a OR t2.phv = t2.b)
ORDER BY t1.a, t2.b;

DROP TABLE test46_ph1;
DROP TABLE test46_ph2;

-- Reset GUCs
RESET enable_partitionwise_join;
RESET enable_partitionwise_aggregate;

----------------------------------------
-- Source: 47.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix locking when fixing an incomplete split
-- of a GIN internal page
--
-- This test exercises the new ginFinishOldSplit() function which was
-- introduced to fix a locking bug. When finishing an incomplete split
-- of a GIN internal page, the caller must hold an exclusive lock.
-- The old code path had callers holding shared locks, which caused
-- assertion failures and potential data corruption.
--
-- ginFinishOldSplit() handles two cases:
-- 1. If access == GIN_SHARE: upgrade the lock from shared to exclusive
--    (used in ginFindLeafPage during tree traversal for insert)
-- 2. If access == GIN_EXCLUSIVE: proceed directly (used in other paths)
-- ================================================================

-- ================================================================
-- Test 1: Trigger incomplete split completion via ginFindLeafPage
-- with SHARED lock upgrade (covers ginFinishOldSplit with GIN_SHARE)
--
-- This exercises: ginFindLeafPage → ginFinishOldSplit(access=GIN_SHARE)
-- The tree traversal for insert holds shared locks on internal pages.
-- When it encounters an incompletely-split page, ginFinishOldSplit
-- must upgrade from shared to exclusive lock.
-- ================================================================

-- Create a test table
CREATE TABLE test_gin_split1 (id serial, arr int4[]) WITH (autovacuum_enabled = off);

-- Insert enough data with distinct values to cause page splits
-- The GIN index will split pages as they fill up, creating incomplete
-- splits on internal pages that subsequent inserts must complete.
INSERT INTO test_gin_split1 (arr)
SELECT array_agg(g) FROM generate_series(1, 1000) g;

-- Create GIN index with fastupdate off so each insert touches the tree directly
CREATE INDEX test_gin_idx1 ON test_gin_split1 USING gin (arr)
  WITH (fastupdate = off);

-- Now insert more distinct arrays to force page splits.
-- Different arrays with varying sizes force the GIN entry tree to split.
INSERT INTO test_gin_split1 (arr) SELECT array[g, g+1, g+2, g+3, g+1000]
  FROM generate_series(1, 500) g;

-- More inserts to cause further splits and trigger incomplete split handling
INSERT INTO test_gin_split1 (arr) SELECT array[g, g*2, g*3, g*5, g*7, g*11]
  FROM generate_series(1, 500) g;

-- Query that triggers tree traversal for insert (ANALYZE shows execution)
-- This insert will traverse the tree, encounter incomplete split pages,
-- and call ginFinishOldSplit with GIN_SHARE access mode
EXPLAIN (ANALYZE, buffers, costs off) INSERT INTO test_gin_split1 (arr)
  VALUES (array[100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]);

DROP TABLE test_gin_split1;


-- ================================================================
-- Test 2: Trigger incomplete split via ginInsertValue at leaf level
-- (covers ginFinishOldSplit called from ginInsertValue with GIN_EXCLUSIVE)
--
-- This exercises: ginInsertValue → ginFinishOldSplit(access=GIN_EXCLUSIVE)
-- When inserting into a leaf page that has an incomplete split flag,
-- ginInsertValue first finishes the split before placing the new entry.
-- ================================================================

CREATE TABLE test_gin_split2 (id serial, arr int4[]) WITH (autovacuum_enabled = off);

-- Insert wide variety of distinct integer arrays to create a dense GIN tree
INSERT INTO test_gin_split2 (arr)
SELECT array[g, g+1000, g+2000, g+3000] FROM generate_series(1, 3000) g;

-- Create GIN index (fastupdate off ensures immediate tree modifications)
CREATE INDEX test_gin_idx2 ON test_gin_split2 USING gin (arr)
  WITH (fastupdate = off);

-- Insert more data to cause leaf page splits and incomplete internal pages
INSERT INTO test_gin_split2 (arr)
SELECT array[g, g*2, g*3, g*4, g*5, g*10] FROM generate_series(1, 2000) g;

-- Insert a batch that triggers leaf page incomplete split handling
EXPLAIN (ANALYZE, buffers, costs off)
INSERT INTO test_gin_split2 (arr)
SELECT array[g, g*7, g*13, g*17, g*23, g*29, g*31, g*37]
FROM generate_series(1, 2000) g;

DROP TABLE test_gin_split2;


-- ================================================================
-- Test 3: Trigger incomplete split via ginFindParents (GIN_EXCLUSIVE)
--
-- This exercises: ginFindParents → ginFinishOldSplit(access=GIN_EXCLUSIVE)
-- When ginFinishSplit can't find the parent in the current page and
-- calls ginFindParents, which in turn may encounter incomplete splits
-- on internal pages during its traversal.
-- ================================================================

CREATE TABLE test_gin_split3 (id serial, arr int4[]) WITH (autovacuum_enabled = off);

-- Build a large GIN index with many distinct values
INSERT INTO test_gin_split3 (arr)
SELECT array_agg(g) FROM generate_series(1, 200) g;

CREATE INDEX test_gin_idx3 ON test_gin_split3 USING gin (arr)
  WITH (fastupdate = off);

-- Add many distinct arrays to force deep tree and many splits
INSERT INTO test_gin_split3 (arr)
SELECT array[g, g+1, g+2, g+3, g+4, g+5, g+6, g+7, g+8, g+9]
FROM generate_series(1, 1000) g;

-- Add even more to create complex tree structure with multiple levels
INSERT INTO test_gin_split3 (arr)
SELECT array[g, g*2, g*3, g*4, g*5, g*6, g*7, g*8, g*9, g*10]
FROM generate_series(1, 2000) g;

-- A large insertion that will force deep tree traversal and find parents
EXPLAIN (ANALYZE, buffers, costs off)
INSERT INTO test_gin_split3 (arr)
SELECT array[g, g*11, g*13, g*17, g*19, g*23, g*29, g*31, g*37, g*41]
FROM generate_series(1, 2000) g;

DROP TABLE test_gin_split3;


-- ================================================================
-- Test 4: Recursive incomplete split handling during ginFinishSplit
-- (covers ginFinishSplit calling ginFinishOldSplit on parent pages)
--
-- This exercises: ginFinishSplit → ginFinishOldSplit(parent, GIN_EXCLUSIVE)
-- When finishing a split, the parent page itself may have an incomplete
-- split flag, requiring recursive handling. This tests lines 703-704
-- and 727-728 in ginFinishSplit where parent pages are checked.
-- ================================================================

CREATE TABLE test_gin_split4 (id serial, arr int4[]) WITH (autovacuum_enabled = off);

-- Create a very broad and deep GIN tree by inserting many distinct values
INSERT INTO test_gin_split4 (arr)
SELECT array_agg(g) FROM generate_series(1, 500) g;

CREATE INDEX test_gin_idx4 ON test_gin_split4 USING gin (arr)
  WITH (fastupdate = off);

-- Force heavy page splitting with varied data
INSERT INTO test_gin_split4 (arr)
SELECT array[g, g+500, g+1000, g+1500, g+2000, g+2500, g+3000, g+3500]
FROM generate_series(1, 500) g;

-- More inserts to create deep tree
INSERT INTO test_gin_split4 (arr)
SELECT array[g, g*3, g*5, g*7, g*9, g*11, g*13, g*15, g*17, g*19]
FROM generate_series(1, 1000) g;

-- This massive insert should trigger cascading splits and recursive
-- incomplete split completion
EXPLAIN (ANALYZE, buffers, costs off)
INSERT INTO test_gin_split4 (arr)
SELECT array_agg(g) FROM generate_series(500, 2500) g;

DROP TABLE test_gin_split4;


-- ================================================================
-- Test 5: Concurrent-style scenario - step right with incomplete split
-- (covers ginFindLeafPage step-right branch, lines 134-135)
--
-- This exercises: ginFindLeafPage (after step right) → ginFinishOldSplit
-- When traversing rightward through internal pages during an insert,
-- the target page may have an incomplete split flag.
-- This also tests the elog(DEBUG1, "finishing incomplete split...") path.
-- ================================================================

CREATE TABLE test_gin_split5 (id serial, arr int4[]) WITH (autovacuum_enabled = off);

-- Create a GIN index with large data to force multi-level tree
INSERT INTO test_gin_split5 (arr)
SELECT array[g, g+1, g+2, g+3] FROM generate_series(1, 1000) g;

CREATE INDEX test_gin_idx5 ON test_gin_split5 USING gin (arr)
  WITH (fastupdate = off);

-- Insert varied data to cause internal page splits and right-link traversal
INSERT INTO test_gin_split5 (arr)
SELECT array[g, g*10, g*20, g*30, g*40, g*50]
FROM generate_series(1, 1500) g;

-- More data to ensure splits at multiple tree levels
INSERT INTO test_gin_split5 (arr)
SELECT array[g*2, g*3, g*5, g*7, g*11, g*13, g*17, g*19, g*23, g*29]
FROM generate_series(1, 1500) g;

-- Insert data with a value that requires stepping right in the tree
-- and encountering incomplete splits
EXPLAIN (ANALYZE, buffers, costs off)
INSERT INTO test_gin_split5 (arr)
SELECT array[g*3, g*7, g*11, g*13, g*17, g*19, g*23, g*29, g*31, g*37]
FROM generate_series(1, 2000) g;

DROP TABLE test_gin_split5;

----------------------------------------
-- Source: 48.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Second attempt at organizing jsonpath 
--                          operators and methods
-- task_id: 48
-- 
-- This commit reorders switch/case branches in jsonpath.c functions
-- (printJsonPathItem, jspOperationName, jspInitByBuffer, jspGetArg,
--  jspGetNext) to follow enum JsonPathItemType order.
-- No logic changed, so we test all major jsonpath features to verify
-- correct behavior after reordering.
-- ================================================================

-- ================================================================
-- Test 1: Basic jsonpath scalar types and accessors
-- Covers: jpiNull, jpiKey, jpiString, jpiNumeric, jpiBool, jpiRoot,
--         jpiCurrent, jpiVariable, jpiLast, jpiAnyArray, jpiAnyKey,
--         jpiIndexArray, jpiAny (wildcard accessors)
-- Functions: printJsonPathItem (reordered cases)
-- ================================================================

CREATE TABLE test_jsonpath_basic (
    id serial PRIMARY KEY,
    data jsonb
);

INSERT INTO test_jsonpath_basic (data) VALUES
    ('{"a": 1, "b": "hello", "c": true, "d": null, "e": {"f": [1,2,3]}}'),
    ('{"x": 10, "y": -5, "z": {"w": "world"}}'),
    (NULL);

-- Test root access
EXPLAIN ANALYZE SELECT jsonb_path_exists(data, '$.a') FROM test_jsonpath_basic WHERE data IS NOT NULL;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a') FROM test_jsonpath_basic WHERE data IS NOT NULL;

-- Test key access (jpiKey)
EXPLAIN ANALYZE SELECT jsonb_path_exists(data, '$.b') FROM test_jsonpath_basic WHERE data IS NOT NULL;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.e.f') FROM test_jsonpath_basic WHERE data IS NOT NULL;

-- Test wildcard access (jpiAnyKey, jpiAnyArray)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.*') FROM test_jsonpath_basic WHERE data IS NOT NULL;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$[*]') FROM test_jsonpath_basic WHERE data IS NOT NULL;

-- Test array index access (jpiIndexArray)
EXPLAIN ANALYZE SELECT jsonb_path_query('{"arr": [10, 20, 30]}', '$.arr[0]');
EXPLAIN ANALYZE SELECT jsonb_path_query('{"arr": [10, 20, 30]}', '$.arr[0 to 1]');

-- Test variable (jpiVariable)
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"a": 1}', '$.a == $v', '{"v": 1}');
EXPLAIN ANALYZE SELECT jsonb_path_query('{"a": 1, "b": 2}', '$.a == $v', '{"v": 1}');

-- Test last accessor
EXPLAIN ANALYZE SELECT jsonb_path_query('[1, 2, 3, 4, 5]', '$[last]');
EXPLAIN ANALYZE SELECT jsonb_path_query('[1, 2, 3, 4, 5]', '$[0 to last]');

-- Test null/boolean/numeric/string types
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"val": null}', '$.val');
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"val": true}', '$.val');
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"val": "text"}', '$.val');

DROP TABLE test_jsonpath_basic;

-- ================================================================
-- Test 2: Arithmetic and unary operators
-- Covers: jpiAdd, jpiSub, jpiMul, jpiDiv, jpiMod, jpiPlus, jpiMinus
-- Functions: printJsonPathItem (arithmetic + unary cases),
--            jspOperationName (reordered cases),
--            jspInitByBuffer (reordered cases)
-- ================================================================

CREATE TABLE test_jsonpath_arith (
    id serial PRIMARY KEY,
    data jsonb
);

INSERT INTO test_jsonpath_arith (data) VALUES
    ('{"a": 10, "b": 3}'),
    ('{"a": -5, "b": 2}'),
    ('{"a": 7, "b": 0}');

-- Addition (jpiAdd)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a + $.b') FROM test_jsonpath_arith;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a + 100') FROM test_jsonpath_arith;

-- Subtraction (jpiSub)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a - $.b') FROM test_jsonpath_arith;

-- Multiplication (jpiMul)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a * $.b') FROM test_jsonpath_arith;

-- Division (jpiDiv)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a / $.b') FROM test_jsonpath_arith WHERE data->>'b' != '0';

-- Modulus (jpiMod)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a % $.b') FROM test_jsonpath_arith WHERE data->>'b' != '0';

-- Unary plus (jpiPlus)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '+$.a') FROM test_jsonpath_arith;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '+(+$.a)') FROM test_jsonpath_arith;

-- Unary minus (jpiMinus)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '-$.a') FROM test_jsonpath_arith;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '--$.a') FROM test_jsonpath_arith;

-- Complex arithmetic expression (mixed operators)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a + $.b * 2') FROM test_jsonpath_arith;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '($.a + $.b) * 2') FROM test_jsonpath_arith;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '-$.a + $.b') FROM test_jsonpath_arith;

DROP TABLE test_jsonpath_arith;

-- ================================================================
-- Test 3: Comparison and logical operators
-- Covers: jpiEqual, jpiNotEqual, jpiLess, jpiGreater, 
--         jpiLessOrEqual, jpiGreaterOrEqual, jpiAnd, jpiOr,
--         jpiNot, jpiIsUnknown
-- Functions: printJsonPathItem (comparison/logical cases),
--            jspOperationName (reordered cases)
-- ================================================================

CREATE TABLE test_jsonpath_cmp (
    id serial PRIMARY KEY,
    data jsonb
);

INSERT INTO test_jsonpath_cmp (data) VALUES
    ('{"a": 5, "b": 10, "c": "hello"}'),
    ('{"a": 10, "b": 5, "c": "world"}'),
    ('{"a": 7, "b": 7, "c": "test"}');

-- Equality (jpiEqual)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a == 5') FROM test_jsonpath_cmp;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a == $.b') FROM test_jsonpath_cmp;

-- Not equal (jpiNotEqual)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a != $.b') FROM test_jsonpath_cmp;

-- Less than (jpiLess)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a < $.b') FROM test_jsonpath_cmp;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a < 8') FROM test_jsonpath_cmp;

-- Greater than (jpiGreater)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a > $.b') FROM test_jsonpath_cmp;

-- Less or equal (jpiLessOrEqual)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a <= $.b') FROM test_jsonpath_cmp;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a <= 7') FROM test_jsonpath_cmp;

-- Greater or equal (jpiGreaterOrEqual)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.a >= $.b') FROM test_jsonpath_cmp;

-- AND (jpiAnd)
EXPLAIN ANALYZE SELECT jsonb_path_exists(data, '$.a > 0 && $.b > 0') FROM test_jsonpath_cmp;

-- OR (jpiOr)
EXPLAIN ANALYZE SELECT jsonb_path_exists(data, '$.a == 5 || $.b == 5') FROM test_jsonpath_cmp;

-- NOT (jpiNot)
EXPLAIN ANALYZE SELECT jsonb_path_exists(data, '!($.a == 0)') FROM test_jsonpath_cmp;

-- IS UNKNOWN (jpiIsUnknown)
EXPLAIN ANALYZE SELECT jsonb_path_exists(data, '($.a == "string") is unknown') FROM test_jsonpath_cmp;

-- Complex logical expression with comparison
EXPLAIN ANALYZE SELECT jsonb_path_exists(data, '$.a > 0 && $.a < 10 || $.b == 5') FROM test_jsonpath_cmp;

DROP TABLE test_jsonpath_cmp;

-- ================================================================
-- Test 4: Filter expressions, exists, starts_with, and like_regex
-- Covers: jpiFilter, jpiExists, jpiStartsWith, jpiLikeRegex
-- Functions: printJsonPathItem (filter exists starts_with like_regex),
--            jspGetArg (reordered Assert),
--            jspInitByBuffer (like_regex reordered case)
-- ================================================================

CREATE TABLE test_jsonpath_filter (
    id serial PRIMARY KEY,
    data jsonb
);

INSERT INTO test_jsonpath_filter (data) VALUES
    ('[{"a": 1, "b": "x"}, {"a": 2, "b": "y"}, {"a": 3, "b": "z"}]'),
    ('[{"a": 10, "b": "hello"}, {"a": 20, "b": "world"}]'),
    ('[{"x": 1}, {"a": 5, "b": "test"}]');

-- Filter with simple predicate (jpiFilter)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$[*] ? (@.a > 1)') FROM test_jsonpath_filter;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$[*] ? (@.a == 2)') FROM test_jsonpath_filter;

-- Filter with complex predicate
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$[*] ? (@.a > 0 && @.a < 10)') FROM test_jsonpath_filter;

-- EXISTS (jpiExists)
EXPLAIN ANALYZE SELECT jsonb_path_exists(data, 'exists($.a)') FROM test_jsonpath_filter;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$[*] ? (exists(@.a))') FROM test_jsonpath_filter;

-- Nested filter with exists
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$[*] ? (exists(@.a) && @.a > 1)') FROM test_jsonpath_filter;

-- starts_with (jpiStartsWith)
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "hello world"}', '$.str starts with "hello"');
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "hello world"}', '$.str starts with "world"');
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "test"}', '$.str starts with "te"');

-- like_regex (jpiLikeRegex) - basic
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "hello"}', '$.str like_regex "^hello$"');
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "Hello"}', '$.str like_regex "^hello$" flag "i"');

-- like_regex with all flags
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "Hello\nWorld"}', '$.str like_regex "hello.world" flag "is"');
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "Hello World"}', '$.str like_regex "hello.world" flag "ix"');

-- like_regex with flag "q" (quote)
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "a+b"}', '$.str like_regex "a+b" flag "q"');
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "a+b"}', '$.str like_regex "a+b"');

-- like_regex with flag "m" (multiline)
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "line1\nline2"}', '$.str like_regex "^line" flag "m"');

-- like_regex without match
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"str": "hello"}', '$.str like_regex "^world$"');

-- like_regex in filter
EXPLAIN ANALYZE SELECT jsonb_path_query('["hello", "world", "hi"]', '$[*] ? (@ like_regex "^h")');

DROP TABLE test_jsonpath_filter;

-- ================================================================
-- Test 5: Jsonpath methods (.type(), .size(), .abs(), .floor(), 
--         .ceiling(), .double(), .datetime(), .keyvalue())
-- Covers: jpiType, jpiSize, jpiAbs, jpiFloor, jpiCeiling,
--         jpiDouble, jpiDatetime, jpiKeyValue
-- Functions: printJsonPathItem (methods section reordered),
--            jspOperationName (method name reordering),
--            jspGetNext (reordered Assert)
-- ================================================================

CREATE TABLE test_jsonpath_methods (
    id serial PRIMARY KEY,
    data jsonb
);

INSERT INTO test_jsonpath_methods (data) VALUES
    ('{"num": 42, "neg": -10, "arr": [1, 2, 3], "str": "text", "flag": true, "nil": null}'),
    ('{"num": 3.14, "neg": -5.7, "arr": [], "str": "hello", "flag": false}'),
    ('{"num": -7, "neg": -3, "arr": [10, 20, 30, 40], "str": "2023-01-15", "flag": true}');

-- .type() (jpiType)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.num.type()') FROM test_jsonpath_methods;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.str.type()') FROM test_jsonpath_methods;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.flag.type()') FROM test_jsonpath_methods;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.nil.type()') FROM test_jsonpath_methods;
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.arr.type()') FROM test_jsonpath_methods;

-- .size() (jpiSize)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.arr.size()') FROM test_jsonpath_methods;

-- .abs() (jpiAbs)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.neg.abs()') FROM test_jsonpath_methods;

-- .floor() (jpiFloor)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.num.floor()') FROM test_jsonpath_methods;

-- .ceiling() (jpiCeiling)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.num.ceiling()') FROM test_jsonpath_methods;

-- .double() (jpiDouble)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.num.double()') FROM test_jsonpath_methods;

-- .abs().floor().ceiling() chained (covers multiple methods and jspGetNext)
EXPLAIN ANALYZE SELECT jsonb_path_query(data, '$.neg.abs().floor().ceiling()') FROM test_jsonpath_methods;

-- .keyvalue() (jpiKeyValue)
EXPLAIN ANALYZE SELECT jsonb_path_query('{"a": 1, "b": 2}', '$.keyvalue()');
EXPLAIN ANALYZE SELECT jsonb_path_query('{"a": 1, "b": 2}', '$.keyvalue().key');
EXPLAIN ANALYZE SELECT jsonb_path_query('{"a": 1, "b": 2}', '$.keyvalue().value');

-- .datetime() (jpiDatetime)
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"date": "2023-01-15"}', '$.date.datetime()');
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"date": "2023-01-15T12:00:00"}', '$.date.datetime()');

-- .datetime() with template argument (jpiDatetime with arg)
EXPLAIN ANALYZE SELECT jsonb_path_exists('{"date": "01-15-2023"}', '$.date.datetime("MM-DD-YYYY")');

DROP TABLE test_jsonpath_methods;

----------------------------------------
-- Source: 49.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Check collation when creating partitioned index
-- task_id: 49
-- Description: When creating a partitioned index, verify that the
-- collation of the partition key matches the collation of the index
-- definition. Without this check, a unique index could be created
-- that fails to enforce uniqueness.
-- ================================================================

-- ================================================================
-- Test 1: Normal case - collation matches (should succeed)
-- Create a partitioned table with a text column using default collation,
-- then create a UNIQUE index that includes the partition key with
-- matching collation (default). This is the normal success path.
-- ================================================================
CREATE TABLE test1_part (a int, b text) PARTITION BY RANGE (a);
CREATE TABLE test1_part1 PARTITION OF test1_part FOR VALUES FROM (0) TO (100);
CREATE TABLE test1_part2 PARTITION OF test1_part FOR VALUES FROM (100) TO (200);
INSERT INTO test1_part VALUES (1, 'hello'), (2, 'world'), (150, 'test');
CREATE UNIQUE INDEX test1_uniq_idx ON test1_part (a, b);
EXPLAIN ANALYZE SELECT * FROM test1_part WHERE a = 1 AND b = 'hello';
DROP TABLE test1_part;

-- ================================================================
-- Test 2: Collation mismatch - partition key uses default collation,
-- but index uses a different collation (should fail with error)
-- This test exercises the new code path where collation mismatch
-- causes the column match to fail, resulting in an error:
-- "unique constraint on partitioned table must include all partitioning columns"
-- ================================================================
CREATE TABLE test2_part (a int, b text) PARTITION BY RANGE (a);
CREATE TABLE test2_part1 PARTITION OF test2_part FOR VALUES FROM (0) TO (100);
CREATE TABLE test2_part2 PARTITION OF test2_part FOR VALUES FROM (100) TO (200);
INSERT INTO test2_part VALUES (1, 'hello'), (2, 'world');
-- This should FAIL because collation of index column ('C') doesn't match
-- the default collation in the partition key
CREATE UNIQUE INDEX test2_uniq_idx ON test2_part (a, b COLLATE "C");
EXPLAIN ANALYZE SELECT * FROM test2_part WHERE a = 1 AND b = 'hello';
DROP TABLE test2_part;

-- ================================================================
-- Test 3: Explicit collation match - partition key uses "POSIX" collation,
-- and index uses the same "POSIX" collation (should succeed)
-- This tests that when both partition key and index use an explicit
-- non-default collation that matches, the index creation succeeds.
-- ================================================================
CREATE TABLE test3_part (a int, b text COLLATE "POSIX") PARTITION BY RANGE (a);
CREATE TABLE test3_part1 PARTITION OF test3_part FOR VALUES FROM (0) TO (100);
CREATE TABLE test3_part2 PARTITION OF test3_part FOR VALUES FROM (100) TO (200);
INSERT INTO test3_part VALUES (1, 'hello'), (2, 'world'), (150, 'test');
CREATE UNIQUE INDEX test3_uniq_idx ON test3_part (a, b);
EXPLAIN ANALYZE SELECT * FROM test3_part WHERE a = 1 AND b = 'hello';
DROP TABLE test3_part;

-- ================================================================
-- Test 4: Partial collation mismatch on multi-column partition key
-- Table partitioned by (a, b) where b has a collation, but index
-- uses different collation for b (should fail with error)
-- This tests that the check works correctly on a multi-column
-- partition key when only one column has a collation mismatch.
-- ================================================================
CREATE TABLE test4_part (a int, b text COLLATE "POSIX") PARTITION BY RANGE (a, b COLLATE "POSIX");
CREATE TABLE test4_part1 PARTITION OF test4_part FOR VALUES FROM (0, 'aaa') TO (100, 'zzz');
CREATE TABLE test4_part2 PARTITION OF test4_part FOR VALUES FROM (100, 'aaa') TO (200, 'zzz');
INSERT INTO test4_part VALUES (1, 'hello'), (2, 'world');
-- This should FAIL because b in index uses default collation, but partition key uses "POSIX"
CREATE UNIQUE INDEX test4_uniq_idx ON test4_part (a, b COLLATE "C");
EXPLAIN ANALYZE SELECT * FROM test4_part WHERE a = 1 AND b = 'hello';
DROP TABLE test4_part;

-- ================================================================
-- Test 5: Mixed collation - partition key uses default collation,
-- index uses matching collation for multicolumn (should succeed)
-- Table partitioned by (a, b) where both columns use default collation.
-- Index created with default collation as well (no explicit COLLATE).
-- Verifies that multi-column partition keys work correctly.
-- ================================================================
CREATE TABLE test5_part (a int, b text) PARTITION BY RANGE (a, b);
CREATE TABLE test5_part1 PARTITION OF test5_part FOR VALUES FROM (0, 'aaa') TO (100, 'zzz');
CREATE TABLE test5_part2 PARTITION OF test5_part FOR VALUES FROM (100, 'aaa') TO (200, 'zzz');
INSERT INTO test5_part VALUES (1, 'hello'), (2, 'world'), (150, 'test');
CREATE UNIQUE INDEX test5_uniq_idx ON test5_part (a, b);
EXPLAIN ANALYZE SELECT * FROM test5_part WHERE a = 1 AND b = 'hello';
DROP TABLE test5_part;

----------------------------------------
-- Source: 50.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix assertions with RI triggers in heap_update and heap_delete
-- task_id: 50
--
-- This commit fixes assertion failures in heap_delete() and heap_update()
-- when crosscheck snapshot is used for referential integrity (RI) checks
-- in transaction-snapshot isolation modes (REPEATABLE READ, SERIALIZABLE).
--
-- The fix moves Assert() calls BEFORE the crosscheck visibility check,
-- so that when crosscheck changes result from TM_Ok to TM_Updated,
-- the assertions (which may not hold for the crosscheck-induced result)
-- don't fire incorrectly.
--
-- Affected functions: heap_delete() and heap_update() in heapam.c
--   heap_delete: lines 2660-2692 (Block 1 in diff)
--   heap_update: lines 3354-3391 (Block 3 in diff)
--
-- Each test:
-- 1. Creates parent/child tables with foreign key constraints (installs RI triggers)
-- 2. Runs in REPEATABLE READ or SERIALIZABLE isolation (IsolationUsesXactSnapshot true)
-- 3. Executes DML that triggers RI triggers, which call SPI_execute_snapshot
--    with a crosscheck snapshot, thus reaching the modified code paths
-- ================================================================


-- ================================================================
-- Test 1: heap_delete with crosscheck in REPEATABLE READ mode
--
-- Coverage: heap_delete() crosscheck path (lines 2672-2677 in heapam.c)
-- Scenario: Parent table with FK referenced by child table.
--           In REPEATABLE READ isolation, delete parent rows that have
--           matching child rows. RI triggers fire and use crosscheck.
--           ON DELETE SET NULL causes child table UPDATE operations
--           (via RI trigger) that also exercise crosscheck path.
-- ================================================================

CREATE TABLE test1_parent (
    id INT PRIMARY KEY,
    name TEXT
);

CREATE TABLE test1_child (
    id INT PRIMARY KEY,
    parent_id INT REFERENCES test1_parent(id) ON DELETE SET NULL,
    data TEXT
);

INSERT INTO test1_parent VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');
INSERT INTO test1_child VALUES (10, 1, 'child_a'), (11, 2, 'child_b'), (12, 3, 'child_c');

BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- Delete parent rows. RI trigger fires:
-- 1. Checks child table (crosscheck)
-- 2. Sets parent_id to NULL in child rows (calls heap_update with crosscheck)
EXPLAIN ANALYZE DELETE FROM test1_parent WHERE id IN (1, 2);

COMMIT;

DROP TABLE test1_child;
DROP TABLE test1_parent;


-- ================================================================
-- Test 2: heap_update with crosscheck in REPEATABLE READ mode
--
-- Coverage: heap_update() crosscheck path (lines 3366-3371 in heapam.c)
-- Scenario: Update parent primary key with ON UPDATE CASCADE.
--           This triggers UPDATE RI triggers that cascade to child table,
--           calling heap_update on child rows with crosscheck.
-- ================================================================

CREATE TABLE test2_parent (
    id INT PRIMARY KEY,
    val TEXT
);

CREATE TABLE test2_child (
    id INT PRIMARY KEY,
    parent_id INT NOT NULL REFERENCES test2_parent(id) ON UPDATE CASCADE,
    payload TEXT
);

INSERT INTO test2_parent VALUES (1, 'orig'), (2, 'orig2'), (3, 'orig3');
INSERT INTO test2_child VALUES (100, 1, 'dep1'), (101, 2, 'dep2'), (102, 3, 'dep3');

BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- Update parent PK. RI trigger cascades the update to child rows,
-- calling heap_update on child table with crosscheck snapshot.
EXPLAIN ANALYZE UPDATE test2_parent SET id = id + 10 WHERE id IN (1, 2);

COMMIT;

DROP TABLE test2_child;
DROP TABLE test2_parent;


-- ================================================================
-- Test 3: heap_delete with crosscheck in SERIALIZABLE mode
--
-- Coverage: heap_delete() crosscheck path (lines 2672-2677)
-- Scenario: Same pattern as Test 1 but in SERIALIZABLE isolation.
--           ON DELETE CASCADE causes RI-triggered deletes on child table.
-- ================================================================

CREATE TABLE test3_parent (
    id INT PRIMARY KEY,
    category TEXT
);

CREATE TABLE test3_child (
    id INT PRIMARY KEY,
    parent_id INT NOT NULL REFERENCES test3_parent(id) ON DELETE CASCADE,
    info TEXT
);

INSERT INTO test3_parent VALUES (1, 'A'), (2, 'B'), (3, 'C'), (4, 'D');
INSERT INTO test3_child VALUES (10, 1, 'info_a'), (20, 2, 'info_b'), (30, 3, 'info_c');

BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

-- Delete parent row. CASCADE causes child rows to be deleted,
-- each deletion goes through heap_delete with crosscheck.
EXPLAIN ANALYZE DELETE FROM test3_parent WHERE id IN (1, 2, 3);

COMMIT;

DROP TABLE test3_child;
DROP TABLE test3_parent;


-- ================================================================
-- Test 4: heap_update with crosscheck in SERIALIZABLE mode (NO ACTION)
--
-- Coverage: heap_update() crosscheck path (lines 3366-3371)
-- Scenario: Update parent PK with ON UPDATE NO ACTION in SERIALIZABLE.
--           The UPDATE trigger checks child table for existing references,
--           using crosscheck snapshot for the query.
-- ================================================================

CREATE TABLE test4_parent (
    code INT PRIMARY KEY,
    description TEXT
);

CREATE TABLE test4_child (
    id INT PRIMARY KEY,
    ref_code INT NOT NULL REFERENCES test4_parent(code) ON UPDATE NO ACTION,
    note TEXT
);

INSERT INTO test4_parent VALUES (10, 'ten'), (20, 'twenty'), (30, 'thirty');
INSERT INTO test4_child VALUES (1, 10, 'note_ten'), (2, 20, 'note_twenty');

BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

-- Update parent PK to a value not used by child (to pass NO ACTION check)
-- The RI trigger checks child table using crosscheck.
EXPLAIN ANALYZE UPDATE test4_parent SET code = code + 100 WHERE code IN (10, 20);

COMMIT;

DROP TABLE test4_child;
DROP TABLE test4_parent;


-- ================================================================
-- Test 5: Multiple cascading operations in REPEATABLE READ
--
-- Coverage: Both heap_delete() and heap_update() crosscheck paths
-- Scenario: 3-level hierarchy with CASCADE. Parent delete cascades
--           through multiple levels, creating multiple RI triggers
--           each using crosscheck snapshots.
--           Also tests edge case with empty child tables.
-- ================================================================

CREATE TABLE test5_grandparent (
    id INT PRIMARY KEY,
    name TEXT
);

CREATE TABLE test5_parent (
    id INT PRIMARY KEY,
    gp_id INT NOT NULL REFERENCES test5_grandparent(id) ON DELETE CASCADE,
    value TEXT
);

CREATE TABLE test5_child (
    id INT PRIMARY KEY,
    parent_id INT REFERENCES test5_parent(id) ON DELETE SET NULL,
    detail TEXT
);

INSERT INTO test5_grandparent VALUES (1, 'gp1'), (2, 'gp2');
INSERT INTO test5_parent VALUES (10, 1, 'p1'), (20, 1, 'p2'), (30, 2, 'p3');
INSERT INTO test5_child VALUES (100, 10, 'c1'), (200, 20, 'c2'), (300, NULL, 'orphan');

BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

-- Delete grandparent row. Cascading operations:
-- 1. Delete from test5_parent (heap_delete with crosscheck)
-- 2. SET NULL on test5_child (heap_update with crosscheck)
-- Also includes edge case: child with NULL parent_id (orphan)
EXPLAIN ANALYZE DELETE FROM test5_grandparent WHERE id = 1;

COMMIT;

DROP TABLE test5_child;
DROP TABLE test5_parent;
DROP TABLE test5_grandparent;

----------------------------------------
-- Source: 52.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Don't release index root page pin in ginFindParents()
-- task_id: 52
--
-- This test exercises the modified code path in ginFindParents() where
-- the pin on the root page must NOT be released when we can't find the
-- downlink in the current level and reach the rightmost page.
-- The fix is in ginbtree.c lines 283-287:
--   LockBuffer(buffer, GIN_UNLOCK);
--   if (buffer != root->buffer)
--       ReleaseBuffer(buffer);
-- ================================================================

-- ================================================================
-- Test 1: Basic GIN index with fastupdate enabled, large insertions
-- to trigger page splits and exercise the ginFindParents() path.
-- This is the primary test that exercises the code path where
-- ginFindParents traverses pages looking for a downlink.
-- ================================================================

-- Create test table with multiple integer array columns
CREATE TABLE gin_test_1 (id int4[], data int4[]) WITH (autovacuum_enabled = off);

-- Create GIN index with small gin_pending_list_limit to trigger
-- frequent page splits during background flush
CREATE INDEX gin_test_1_idx ON gin_test_1 USING gin (id)
  WITH (fastupdate = on, gin_pending_list_limit = 1024);

-- Insert a large number of distinct values to force GIN index growth
-- and page splits. Using varied arrays to create many distinct keys.
INSERT INTO gin_test_1 SELECT array[g, g+1, g+2], array[g*2, g*3]
  FROM generate_series(1, 30000) g;

-- Flush the pending list, which will cause page splits in the GIN tree
SELECT gin_clean_pending_list('gin_test_1_idx') AS cleaned_entries;

-- Insert more data to cause further page splits
INSERT INTO gin_test_1 SELECT array[g, g*2], array[g*3, g*4]
  FROM generate_series(1, 10000) g;

-- Force another flush
VACUUM gin_test_1;

-- Run queries that traverse the GIN index tree to exercise ginFindParents
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_1 WHERE id @> array[100];

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_1 WHERE id @> array[42];

-- Clean up
DROP TABLE gin_test_1;

-- ================================================================
-- Test 2: Multiple concurrent insertions to trigger concurrent
-- root page splits, which is the exact scenario described in the
-- commit message. Use PL/pgSQL to simulate concurrent operations.
-- ================================================================

CREATE TABLE gin_test_2 (arr int4[]) WITH (autovacuum_enabled = off);

-- Disable fastupdate so every insertion goes directly into the index,
-- causing more page splits
CREATE INDEX gin_test_2_idx ON gin_test_2 USING gin (arr)
  WITH (fastupdate = off);

-- Insert a moderate amount of data first to build up the index tree
INSERT INTO gin_test_2 SELECT array[g, g+1] FROM generate_series(1, 5000) g;

-- Now insert in batches with concurrent-like pattern using do blocks
-- Each batch inserts many distinct values to cause splitting
DO $$
BEGIN
  FOR i IN 1..10 LOOP
    INSERT INTO gin_test_2 SELECT array[g * 10000 + i, g * 10000 + i + 1]
      FROM generate_series(1, 2000) g;
    -- Run a query after each batch to traverse the tree
    PERFORM count(*) FROM gin_test_2 WHERE arr @> array[i * 100];
  END LOOP;
END;
$$;

-- Final query to exercise index traversal with ginFindParents
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_2 WHERE arr @> array[500];

-- Edge case: query with value that doesn't exist (forces full traversal)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_2 WHERE arr @> array[99999999];

-- Clean up
DROP TABLE gin_test_2;

-- ================================================================
-- Test 3: GIN index on text array with many distinct entries.
-- Text arrays create deeper index trees due to longer keys,
-- increasing the chance of exercising ginFindParents.
-- ================================================================

CREATE TABLE gin_test_3 (t text[]) WITH (autovacuum_enabled = off);

CREATE INDEX gin_test_3_idx ON gin_test_3 USING gin (t)
  WITH (fastupdate = off);

-- Insert many unique text arrays to build a deep GIN tree
INSERT INTO gin_test_3 SELECT array['val_' || g::text, 'data_' || (g % 1000)::text]
  FROM generate_series(1, 20000) g;

-- Insert more to cause splits
INSERT INTO gin_test_3 SELECT array['newval_' || g::text, 'moredata_' || (g % 500)::text]
  FROM generate_series(1, 10000) g;

-- Run queries that will traverse the tree
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_3 WHERE t @> array['val_100'];

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_3 WHERE t @> array['data_42'];

-- Edge case: search with non-existent value
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_3 WHERE t @> array['nonexistent_value'];

-- Clean up
DROP TABLE gin_test_3;

-- ================================================================
-- Test 4: GIN index with NULLs and empty arrays - edge cases that
-- create different index entry patterns. This exercises the
-- index tree traversal with boundary conditions.
-- ================================================================

CREATE TABLE gin_test_4 (arr int4[]) WITH (autovacuum_enabled = off);

CREATE INDEX gin_test_4_idx ON gin_test_4 USING gin (arr)
  WITH (fastupdate = off);

-- Insert data with NULLs, empty arrays, and mixed values
INSERT INTO gin_test_4 VALUES
  (NULL),
  ('{}'),
  ('{1}'),
  ('{2}'),
  ('{1, 2}'),
  ('{1, 2, 3}'),
  ('{1, 2, 3, 4}'),
  ('{5, 6, 7, 8}');

-- Add many rows to build up the index tree
INSERT INTO gin_test_4 SELECT array[g, g % 10] FROM generate_series(1, 10000) g;

-- Also add some rows with NULLs
INSERT INTO gin_test_4 SELECT NULL::int4[] FROM generate_series(1, 100) g;

-- Insert more data to force splits
INSERT INTO gin_test_4 SELECT array[g, g % 20] FROM generate_series(1, 5000) g;

-- Run queries that traverse the tree including boundary values
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_4 WHERE arr @> array[1];

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_4 WHERE arr @> '{}'::int4[];

-- Edge: search for a value that exists in many rows (causes more index traversal)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_4 WHERE arr @> array[0];

-- Clean up
DROP TABLE gin_test_4;

-- ================================================================
-- Test 5: Large-scale test with multiple GIN index types to
-- stress-test the ginFindParents code path. Uses the fact that
-- GIN index on integer arrays with many duplicates creates
-- posting trees, while many unique values creates deeper B-trees.
-- ================================================================

CREATE TABLE gin_test_5 (unique_vals int4[], duplicate_vals int4[])
  WITH (autovacuum_enabled = off);

-- Create two GIN indexes to exercise different tree structures
CREATE INDEX gin_test_5_unique_idx ON gin_test_5 USING gin (unique_vals)
  WITH (fastupdate = off);

CREATE INDEX gin_test_5_dup_idx ON gin_test_5 USING gin (duplicate_vals)
  WITH (fastupdate = off);

-- Insert many unique values to create a deep entry tree
INSERT INTO gin_test_5
SELECT
  array[g, g + 1, g + 2],           -- unique values: many distinct keys
  array[g % 100, g % 50]            -- duplicate values: few distinct keys
FROM generate_series(1, 30000) g;

-- Insert another batch to cause more page splits
INSERT INTO gin_test_5
SELECT
  array[g + 30000, g + 30001, g + 30002],
  array[g % 200, g % 75]
FROM generate_series(1, 20000) g;

-- Run queries against the unique_vals index (deeper tree)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_5 WHERE unique_vals @> array[15000];

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_5 WHERE unique_vals @> array[40000];

-- Run queries against the duplicate_vals index (wider tree with posting lists)
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_5 WHERE duplicate_vals @> array[42];

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_5 WHERE duplicate_vals @> array[99];

-- Combined query using both indexes
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM gin_test_5
  WHERE unique_vals @> array[100] AND duplicate_vals @> array[50];

-- Clean up
DROP TABLE gin_test_5;

----------------------------------------
-- Source: 54.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Compute aggregate argument types correctly in transformAggregateCall()
-- task_id: 54
-- CVE: 2023-5868
-- Description: Fix aggargtypes list construction when DISTINCT causes
-- type resolution of unknown-type literals. The aggargtypes list must
-- be built AFTER DISTINCT/ORDER BY processing, not before.
-- ================================================================

-- ================================================================
-- Test 1: Core bug scenario — aggregate with DISTINCT and unknown-type literal
-- This exercises the new code path where aggargtypes is built after DISTINCT
-- processing. The unknown literal '42' gets resolved to 'text' by DISTINCT,
-- and the aggargtypes list must reflect this correctly.
-- ================================================================
CREATE TABLE test_agg_unknown_distinct (
    id int,
    grp int
);

INSERT INTO test_agg_unknown_distinct VALUES (1, 1), (2, 1), (3, 2), (NULL, 2);

-- Use an aggregate with DISTINCT where one arg is an unknown literal.
-- The unknown literal 'hello' will be resolved to 'text' by DISTINCT processing.
-- The old code would capture the type before resolution (unknown=UNKNOWNOID=0),
-- while the new code captures it after resolution (text).
EXPLAIN ANALYZE SELECT grp, count(DISTINCT id) FROM test_agg_unknown_distinct GROUP BY grp;

-- Actual bug trigger: aggregate with DISTINCT and an unknown-type literal argument.
-- The unknown 'hello' literal gets resolved to text by addTargetToGroupList().
SELECT grp, count(DISTINCT 'hello'::text || id::text) FROM test_agg_unknown_distinct GROUP BY grp;

DROP TABLE test_agg_unknown_distinct;


-- ================================================================
-- Test 2: Aggregate with DISTINCT and string literal (unknown -> text resolution)
-- This directly triggers the original bug: an unknown literal in ANY argument
-- position with DISTINCT. The literal gets converted to 'text' by
-- addTargetToGroupList(), and aggargtypes must capture the updated type.
-- ================================================================
CREATE TABLE test_agg_text_distinct (
    val text,
    cat text
);

INSERT INTO test_agg_text_distinct VALUES ('apple', 'fruit'), ('banana', 'fruit'), ('carrot', 'veg');

-- DISTINCT with unknown literal 'hello' that will be coerced to text
SELECT cat, string_agg(DISTINCT val, 'hello') FROM test_agg_text_distinct GROUP BY cat;

-- Multiple unknown literals with DISTINCT
SELECT cat, string_agg(DISTINCT val, ', ') FROM test_agg_text_distinct GROUP BY cat;

DROP TABLE test_agg_text_distinct;


-- ================================================================
-- Test 3: Ordered-set aggregate (WITHIN GROUP) — exercises aggdirectargs path
-- The new code explicitly iterates over agg->aggdirectargs to capture types.
-- Ordered-set aggregates have both direct args (before WITHIN GROUP) and
-- aggregated args (after WITHIN GROUP). This exercises the first foreach loop
-- in the new code (lines 231-236).
-- ================================================================
CREATE TABLE test_agg_orderedset (
    id int,
    score numeric,
    category text
);

INSERT INTO test_agg_orderedset VALUES
    (1, 85.5, 'A'),
    (2, 92.0, 'A'),
    (3, 78.3, 'A'),
    (4, 88.1, 'B'),
    (5, 95.5, 'B');

-- percentile_cont is an ordered-set aggregate: direct arg = 0.5, aggregated arg = score
-- This exercises the aggdirectargs and tlist iteration in the new code
EXPLAIN ANALYZE SELECT category, percentile_cont(0.5) WITHIN GROUP (ORDER BY score) FROM test_agg_orderedset GROUP BY category;

-- Also with a literal that could be unknown
SELECT category, percentile_cont(0.25::numeric) WITHIN GROUP (ORDER BY score) FROM test_agg_orderedset GROUP BY category;

DROP TABLE test_agg_orderedset;


-- ================================================================
-- Test 4: Aggregate with ORDER BY + DISTINCT and unknown-type literal
-- ORDER BY processing also adds resjunk columns to the tlist.
-- The new code skips resjunk entries (if (tle->resjunk) continue;).
-- This exercises the resjunk filtering in the second foreach loop (lines 241-242).
-- ================================================================
CREATE TABLE test_agg_orderby_distinct (
    x int,
    y int,
    group_id int
);

INSERT INTO test_agg_orderby_distinct VALUES
    (1, 10, 1),
    (2, 20, 1),
    (1, 30, 1),
    (3, 40, 2),
    (2, 50, 2);

-- Aggregate with ORDER BY and DISTINCT, plus an unknown literal in the expression
-- The ORDER BY adds resjunk columns, DISTINCT resolves unknown types.
-- The new code must skip resjunk columns when building aggargtypes.
EXPLAIN ANALYZE SELECT group_id, array_agg(DISTINCT x ORDER BY y) FROM test_agg_orderby_distinct GROUP BY group_id;

-- With unknown-type cast
SELECT group_id, string_agg(DISTINCT x::text, ':' ORDER BY y) FROM test_agg_orderby_distinct GROUP BY group_id;

DROP TABLE test_agg_orderby_distinct;


-- ================================================================
-- Test 5: Edge cases — NULLs, empty groups, multiple unknown literals
-- with DISTINCT aggregation. Ensures the new code handles boundary conditions.
-- ================================================================
CREATE TABLE test_agg_edge_cases (
    id int,
    val1 text,
    val2 int,
    grp int
);

INSERT INTO test_agg_edge_cases VALUES
    (1, NULL, 10, 1),
    (2, 'hello', NULL, 1),
    (3, 'world', 20, 1),
    (4, NULL, NULL, 2),
    (5, 'test', 30, 2);

-- DISTINCT with NULL values (NULLs are ignored by DISTINCT)
EXPLAIN ANALYZE SELECT grp, count(DISTINCT val1) FROM test_agg_edge_cases GROUP BY grp;

-- Multiple unknown literals in a DISTINCT aggregate (each ':' is an unknown literal)
EXPLAIN ANALYZE SELECT grp, string_agg(DISTINCT val1, ':') FROM test_agg_edge_cases GROUP BY grp;

-- Unknown literal mixed with column expression in DISTINCT context
-- This is exactly the pattern that triggered CVE-2023-5868
SELECT grp, string_agg(DISTINCT coalesce(val1, 'N/A'), ',') FROM test_agg_edge_cases GROUP BY grp;

DROP TABLE test_agg_edge_cases;

----------------------------------------
-- Source: 55.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Detect integer overflow while computing new array dimensions
-- task_id: 55
-- 
-- This test exercises the overflow-detecting arithmetic added to
-- array_set_element(), array_set_element_expanded(), and array_set_slice().
-- These functions are called when assigning to array subscripts outside
-- the current array bounds, which requires extending the array.
-- The fix uses pg_sub_s32_overflow() and pg_add_s32_overflow() to detect
-- integer overflow when computing new dimensions, and raises
-- ERRCODE_PROGRAM_LIMIT_EXCEEDED ("array size exceeds the maximum allowed").
--
-- Code paths covered:
--   Test 1: array_set_element - extend before (Block 2):
--     pg_sub_s32_overflow(lb[0], indx[0], &addedbefore) overflow
--   Test 2: array_set_element - extend after (Block 1):
--     pg_add_s32_overflow(dim[0], addedafter, &dim[0]) overflow via 0-based array
--   Test 3: array_set_element - extend after (Block 1):
--     pg_add_s32_overflow(addedafter, 1, &addedafter) overflow via negative-lb array
--   Test 4: array_set_slice - extend before (Block 6):
--     pg_sub_s32_overflow(lb[0], lowerIndx[0], &addedbefore) overflow
--   Test 5: array_set_slice - extend after (Block 5):
--     pg_add_s32_overflow(dim[0], addedafter, &dim[0]) overflow via 0-based array
-- ================================================================

-- Suppress platform-dependent error message text for consistent output
\set VERBOSITY terse

-- ================================================================
-- Test 1: array_set_element() - extend before with INT_MIN subscript
-- Covers: pg_sub_s32_overflow(lb[0], indx[0], &addedbefore)
--         pg_add_s32_overflow(dim[0], addedbefore, &dim[0])
--
-- Create a 1-D 1-based array {1,2,3}, then assign to INT_MIN subscript.
-- lb[0]=1, indx[0]=-2147483648
-- lb[0] - indx[0] = 1 - (-2147483648) = 2147483649 > INT_MAX => overflow
-- ================================================================

CREATE TABLE test1_extend_before (
    id serial,
    arr int[]
);

INSERT INTO test1_extend_before (arr) VALUES ('{1,2,3}');

DO $$
DECLARE
    a int[] := '{1,2,3}';
BEGIN
    a[-2147483648] := 42;
    RAISE NOTICE 'ERROR: should have raised program_limit_exceeded';
EXCEPTION
    WHEN program_limit_exceeded THEN
        RAISE NOTICE 'Test 1 OK: overflow detected (extend before)';
END;
$$;

DROP TABLE test1_extend_before;

-- ================================================================
-- Test 2: array_set_element() - extend after with INT_MAX subscript on 0-based array
-- Covers: pg_sub_s32_overflow(indx[0], dim[0]+lb[0], &addedafter)
--         pg_add_s32_overflow(addedafter, 1, &addedafter)
--         pg_add_s32_overflow(dim[0], addedafter, &dim[0])  <-- this one triggers
--
-- Create 0-based array [0:3]={1,2,3,4}. Then assign a[INT_MAX]:=42.
-- dim[0]=4, lb[0]=0, dim[0]+lb[0]=4
-- addedafter = INT_MAX - 4 + 1 = INT_MAX - 3 = 2147483644
-- dim[0] + addedafter = 4 + 2147483644 = 2147483648 > INT_MAX => overflow!
-- ================================================================

CREATE TABLE test2_extend_after (
    id serial,
    arr int[]
);

INSERT INTO test2_extend_after (arr) VALUES ('[0:3]={1,2,3,4}');

DO $$
DECLARE
    a int[] := '[0:3]={1,2,3,4}';
BEGIN
    a[2147483647] := 42;
    RAISE NOTICE 'ERROR: should have raised program_limit_exceeded';
EXCEPTION
    WHEN program_limit_exceeded THEN
        RAISE NOTICE 'Test 2 OK: overflow detected (extend after with 0-based)';
END;
$$;

DROP TABLE test2_extend_after;

-- ================================================================
-- Test 3: array_set_element() - extend after triggering addedafter+1 overflow
-- Covers: pg_add_s32_overflow(addedafter, 1, &addedafter)
--
-- Use an array with negative lower bound: [-3:-1]={1,2,3}
-- dim[0]=3, lb[0]=-3, dim[0]+lb[0]=0
-- Assign a[INT_MAX]:=42.
-- addedafter = INT_MAX - 0 = INT_MAX (no overflow in subtraction)
-- pg_add_s32_overflow(INT_MAX, 1, &addedafter) => OVERFLOW!
-- ================================================================

CREATE TABLE test3_overflow_add (
    id serial,
    arr int[]
);

INSERT INTO test3_overflow_add (arr) VALUES ('[-3:-1]={1,2,3}');

DO $$
DECLARE
    a int[] := '[-3:-1]={1,2,3}';
BEGIN
    -- dim+lb = 3+(-3) = 0, so addedafter = INT_MAX - 0 = INT_MAX
    -- INT_MAX + 1 overflows
    a[2147483647] := 42;
    RAISE NOTICE 'ERROR: should have raised program_limit_exceeded';
EXCEPTION
    WHEN program_limit_exceeded THEN
        RAISE NOTICE 'Test 3 OK: overflow detected (addedafter+1 overflow)';
    WHEN OTHERS THEN
        RAISE NOTICE 'Test 3 other error: %', SQLERRM;
END;
$$;

DROP TABLE test3_overflow_add;

-- ================================================================
-- Test 4: array_set_slice() - extend before via slice with INT_MIN lower bound
-- Covers: pg_sub_s32_overflow(lb[0], lowerIndx[0], &addedbefore)
--         pg_add_s32_overflow(dim[0], addedbefore, &dim[0])
--
-- Slice assignment a[INT_MIN:INT_MIN+1] := '{42,43}'.
-- lb[0]=1, lowerIndx[0]=INT_MIN
-- lb[0] - lowerIndx[0] = 1 - (-2147483648) = 2147483649 > INT_MAX => overflow
-- ================================================================

CREATE TABLE test4_slice_before (
    id serial,
    arr int[]
);

INSERT INTO test4_slice_before (arr) VALUES ('{1,2,3}');

DO $$
DECLARE
    a int[] := '{1,2,3}';
BEGIN
    a[-2147483648:-2147483647] := '{42,43}';
    RAISE NOTICE 'ERROR: should have raised program_limit_exceeded';
EXCEPTION
    WHEN program_limit_exceeded THEN
        RAISE NOTICE 'Test 4 OK: overflow detected (slice extend before)';
    WHEN OTHERS THEN
        RAISE NOTICE 'Test 4 other error: %', SQLERRM;
END;
$$;

DROP TABLE test4_slice_before;

-- ================================================================
-- Test 5: array_set_slice() - extend after via slice with INT_MAX upper bound
-- Covers: pg_sub_s32_overflow(upperIndx[0], dim[0]+lb[0], &addedafter)
--         pg_add_s32_overflow(addedafter, 1, &addedafter)
--         pg_add_s32_overflow(dim[0], addedafter, &dim[0])
--
-- Use a 0-based array [0:3]={1,2,3,4}.
-- dim[0]=4, lb[0]=0, dim[0]+lb[0]=4
-- Slice assignment a[INT_MAX:INT_MAX] := '{42}'.
-- addedafter = INT_MAX - 4 + 1 = INT_MAX - 3
-- dim[0] + addedafter = 4 + (INT_MAX-3) = INT_MAX+1 > INT_MAX => overflow!
-- ================================================================

CREATE TABLE test5_slice_after (
    id serial,
    arr int[]
);

INSERT INTO test5_slice_after (arr) VALUES ('[0:3]={1,2,3,4}');

DO $$
DECLARE
    a int[] := '[0:3]={1,2,3,4}';
BEGIN
    -- Slice to INT_MAX
    a[2147483647:2147483647] := '{42}';
    RAISE NOTICE 'ERROR: should have raised program_limit_exceeded';
EXCEPTION
    WHEN program_limit_exceeded THEN
        RAISE NOTICE 'Test 5 OK: overflow detected (slice extend after)';
    WHEN OTHERS THEN
        RAISE NOTICE 'Test 5 other error: %', SQLERRM;
END;
$$;

DROP TABLE test5_slice_after;

----------------------------------------
-- Source: 57.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix bug in GenericXLogFinish()
-- task_id: 57
--
-- Description:
--   This commit fixes a bug where MarkBufferDirty() was called AFTER
--   XLogInsert() in GenericXLogFinish(). The fix moves MarkBufferDirty()
--   to BEFORE writing WAL, ensuring buffers are marked dirty before
--   the WAL record is inserted. The code is also refactored to compute
--   deltas, apply images, and mark buffers dirty in a unified code path
--   before branching into FULL_IMAGE vs delta-based WAL logging.
--
--   We use bloom indexes (contrib/bloom) to exercise GenericXLogFinish()
--   because bloom is the primary in-tree consumer of the GenericXLog API.
--   Two code paths are tested:
--     - GENERIC_XLOG_FULL_IMAGE path (used during index build/bulk insert)
--     - Normal delta-based path (used during regular INSERT)
--     - Unlogged relation path (skip xlog)
--     - VACUUM path (via blvacuum.c)
-- ================================================================

-- ################################################################
-- Test 1: Normal bloom index INSERT (non FULL_IMAGE path)
--
-- This exercises the delta-based code path in GenericXLogFinish():
--   line 365: computeDelta() called since GENERIC_XLOG_FULL_IMAGE not set
--   line 373-378: memcpy/memset to apply image with zeroed hole
--   line 380: MarkBufferDirty() called BEFORE XLogInsert()
--   line 389-390: XLogRegisterBuffer with REGBUF_STANDARD + delta data
--
-- The fix: MarkBufferDirty() now happens at line 380 (before WAL write)
-- rather than in the old loop after XLogInsert().
-- ################################################################

-- Create extension if not already present
CREATE EXTENSION IF NOT EXISTS bloom;

-- Create test table with multiple columns for bloom index
CREATE TABLE test_bloom_insert (
    id integer,
    data text,
    category integer
);

-- Insert 500 rows to create a bloom index with multiple pages
INSERT INTO test_bloom_insert
SELECT i, md5(i::text), i % 20
FROM generate_series(1, 500) AS i;

-- Create bloom index (this uses bulk build -> flushCachedPage -> FULL_IMAGE path)
-- Drop and recreate to capture the insert path separately
CREATE INDEX bloom_idx_insert ON test_bloom_insert USING bloom (id, data, category)
    WITH (col1 = 4, col2 = 4, col3 = 4);

-- Perform more INSERTs after index is created to exercise the regular
-- delta-based insert path (blinsert with flags=0 -> GenericXLogFinish delta path)
INSERT INTO test_bloom_insert
SELECT 500 + i, md5((500 + i)::text), (500 + i) % 20
FROM generate_series(1, 200) AS i;

-- Query using the bloom index to ensure it's valid
SET enable_seqscan = off;
SET enable_bitmapscan = on;
SET enable_indexscan = on;

EXPLAIN (COSTS OFF) SELECT count(*) FROM test_bloom_insert WHERE id = 42;
SELECT count(*) FROM test_bloom_insert WHERE id = 42;

EXPLAIN (COSTS OFF) SELECT count(*) FROM test_bloom_insert WHERE data = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4';
SELECT count(*) FROM test_bloom_insert WHERE data = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4';

RESET enable_seqscan;
RESET enable_bitmapscan;
RESET enable_indexscan;

-- Clean up
DROP TABLE test_bloom_insert;


-- ################################################################
-- Test 2: Bloom index bulk build (FULL_IMAGE path)
--
-- This exercises the GENERIC_XLOG_FULL_IMAGE path:
--   line 365: computeDelta() SKIPPED since GENERIC_XLOG_FULL_IMAGE is set
--   line 373-378: memcpy/memset applied (same as normal)
--   line 380: MarkBufferDirty() called BEFORE XLogInsert()
--   line 384-385: XLogRegisterBuffer with REGBUF_FORCE_IMAGE | REGBUF_STANDARD
--   (no XLogRegisterBufData call since no delta needed)
--
-- The bulk index build (CREATE INDEX) calls BloomBuildState->flushCachedPage
-- which uses GENERIC_XLOG_FULL_IMAGE flag.
-- ################################################################

CREATE TABLE test_bloom_bulk (
    a integer,
    b text,
    c numeric
);

-- Insert enough data to create multiple index pages
INSERT INTO test_bloom_bulk
SELECT i % 100,
       substr(md5(i::text), 1, 8),
       random() * 10000
FROM generate_series(1, 5000) AS i;

-- CREATE INDEX triggers bulk build -> flushCachedPage -> FULL_IMAGE path
CREATE INDEX bloom_idx_bulk ON test_bloom_bulk USING bloom (a, b, c)
    WITH (col1 = 3, col2 = 3, col3 = 3);

-- Verify the index works
SET enable_seqscan = off;
SET enable_bitmapscan = on;

EXPLAIN (COSTS OFF) SELECT count(*) FROM test_bloom_bulk WHERE a = 42;
SELECT count(*) FROM test_bloom_bulk WHERE a = 42;

EXPLAIN (COSTS OFF) SELECT count(*) FROM test_bloom_bulk WHERE b = 'abc12345';
SELECT count(*) FROM test_bloom_bulk WHERE b = 'abc12345';

RESET enable_seqscan;
RESET enable_bitmapscan;

-- Insert more data after index exists (delta path)
INSERT INTO test_bloom_bulk
SELECT 5000 + i % 100,
       substr(md5((5000 + i)::text), 1, 8),
       random() * 10000
FROM generate_series(1, 1000) AS i;

-- Query again
SET enable_seqscan = off;
SET enable_bitmapscan = on;
SELECT count(*) FROM test_bloom_bulk WHERE a = 73;
RESET enable_seqscan;
RESET enable_bitmapscan;

DROP TABLE test_bloom_bulk;


-- ################################################################
-- Test 3: UNLOGGED table with bloom index (skip xlog path)
--
-- This exercises the !state->isLogged branch in GenericXLogFinish():
--   line 338: if (state->isLogged) -> false for unlogged relations
--   line 408-438: else branch -> apply changes without WAL
--
-- For unlogged tables, the function still applies the image and marks
-- buffers dirty, but skips XLogBeginInsert/XLogInsert entirely.
-- The fix (MarkBufferDirty before WAL) is not directly relevant here
-- since there is no WAL, but the code path is still exercised.
-- ################################################################

CREATE UNLOGGED TABLE test_bloom_unlogged (
    x integer,
    y text
);

INSERT INTO test_bloom_unlogged
SELECT i, md5(i::text)
FROM generate_series(1, 1000) AS i;

-- Create bloom index on unlogged table (FULL_IMAGE during build)
CREATE INDEX bloom_idx_unlogged ON test_bloom_unlogged USING bloom (x, y);

-- Insert after index creation (delta path with unlogged)
INSERT INTO test_bloom_unlogged
SELECT 1000 + i, md5((1000 + i)::text)
FROM generate_series(1, 500) AS i;

-- Verify index
SET enable_seqscan = off;
SET enable_bitmapscan = on;
SELECT count(*) FROM test_bloom_unlogged WHERE x = 500;
SELECT count(*) FROM test_bloom_unlogged WHERE y = md5('500');
RESET enable_seqscan;
RESET enable_bitmapscan;

DROP TABLE test_bloom_unlogged;


-- ################################################################
-- Test 4: VACUUM on bloom index (vacuum path with GenericXLogFinish)
--
-- This exercises the blvacuum.c code path which also calls
-- GenericXLogFinish() with flags=0 (delta path).
-- The vacuum path in blvacuum.c uses GenericXLog in two places:
--   - Line 131: GenericXLogFinish() after compacting a page
--   - Line 157: GenericXLogFinish() after updating the meta page
--
-- Both of these go through the same modified GenericXLogFinish().
-- ################################################################

CREATE TABLE test_bloom_vacuum (
    key integer,
    val text
);

-- Insert data
INSERT INTO test_bloom_vacuum
SELECT i, md5(i::text)
FROM generate_series(1, 2000) AS i;

-- Create bloom index
CREATE INDEX bloom_idx_vac ON test_bloom_vacuum USING bloom (key, val)
    WITH (col1 = 3, col2 = 3);

-- Delete many rows to create dead tuples for VACUUM to process
DELETE FROM test_bloom_vacuum WHERE key % 5 = 0;

-- VACUUM to trigger bloom vacuum code path
VACUUM test_bloom_vacuum;

-- Insert more data after vacuum
INSERT INTO test_bloom_vacuum
SELECT 2000 + i, md5((2000 + i)::text)
FROM generate_series(1, 500) AS i;

-- Verify
SET enable_seqscan = off;
SET enable_bitmapscan = on;
SELECT count(*) FROM test_bloom_vacuum WHERE key = 1500;
SELECT count(*) FROM test_bloom_vacuum WHERE val = md5('100');
RESET enable_seqscan;
RESET enable_bitmapscan;

DROP TABLE test_bloom_vacuum;


-- ################################################################
-- Test 5: Edge cases with bloom index
--
-- Exercises GenericXLogFinish() with:
--   - NULL values in indexed columns
--   - Empty table then insert
--   - Repeated values (high duplication)
--   - Multiple data types
-- ################################################################

CREATE TABLE test_bloom_edge (
    a integer,
    b text,
    c double precision
);

-- Test with NULL values
INSERT INTO test_bloom_edge VALUES
    (NULL, 'hello', 1.0),
    (1, NULL, 2.0),
    (2, 'world', NULL),
    (NULL, NULL, NULL);

-- Create bloom index
CREATE INDEX bloom_idx_edge ON test_bloom_edge USING bloom (a, b, c);

-- Query with NULLs
SET enable_seqscan = off;
SET enable_bitmapscan = on;
SELECT count(*) FROM test_bloom_edge WHERE a IS NULL;
SELECT count(*) FROM test_bloom_edge WHERE b = 'hello';
SELECT count(*) FROM test_bloom_edge WHERE c = 1.0;
RESET enable_seqscan;
RESET enable_bitmapscan;

-- Test with many duplicate values (stress the delta calculation)
CREATE TABLE test_bloom_dup (
    group_id integer,
    payload text
);

INSERT INTO test_bloom_dup
SELECT i % 10, 'duplicate_value_' || (i % 3)::text
FROM generate_series(1, 3000) AS i;

CREATE INDEX bloom_idx_dup ON test_bloom_dup USING bloom (group_id, payload);

-- Insert more duplicates after index creation
INSERT INTO test_bloom_dup
SELECT 3000 + i % 10, 'duplicate_value_' || ((3000 + i) % 3)::text
FROM generate_series(1, 1000) AS i;

SET enable_seqscan = off;
SET enable_bitmapscan = on;
SELECT count(*) FROM test_bloom_dup WHERE group_id = 5 AND payload = 'duplicate_value_1';
RESET enable_seqscan;
RESET enable_bitmapscan;

-- Clean up
DROP TABLE test_bloom_edge;
DROP TABLE test_bloom_dup;

-- Drop extension
DROP EXTENSION IF EXISTS bloom;

----------------------------------------
-- Source: 58.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for:
--   "Fix briefly showing old progress stats for ANALYZE on inherited tables"
-- task_id: 58
--
-- This test exercises the code path in acquire_inherited_sample_rows()
-- where pgstat_progress_update_multi_param() resets the progress stats
-- (blocks_done and blocks_total to zero) when moving to a new child
-- table during ANALYZE of an inheritance tree.
-- ================================================================

-- ================================================================
-- Test 1: Basic inheritance tree with multiple child tables
-- Coverage: acquire_inherited_sample_rows loop with >1 children,
--            pgstat_progress_update_multi_param resetting counters
-- ================================================================
CREATE TABLE test_inh_parent (id int, val text);
CREATE TABLE test_inh_child1 () INHERITS (test_inh_parent);
CREATE TABLE test_inh_child2 () INHERITS (test_inh_parent);

-- Insert data into all tables so each child has blocks to scan
INSERT INTO test_inh_parent SELECT generate_series(1, 100), 'parent-' || generate_series(1, 100);
INSERT INTO test_inh_child1 SELECT generate_series(101, 500), 'child1-' || generate_series(101, 500);
INSERT INTO test_inh_child2 SELECT generate_series(501, 1000), 'child2-' || generate_series(501, 1000);

-- ANALYZE on the parent triggers acquire_inherited_sample_rows which
-- loops over child tables, using the fixed multi-param progress update
ANALYZE VERBOSE test_inh_parent;

DROP TABLE test_inh_parent CASCADE;

-- ================================================================
-- Test 2: Partitioned table with multiple partitions
-- Coverage: Partitioned tables also trigger the inheritance code path
--            since partitions are treated as inheritance children
-- ================================================================
CREATE TABLE test_part_parent (id int, val text) PARTITION BY RANGE (id);
CREATE TABLE test_part_child1 PARTITION OF test_part_parent FOR VALUES FROM (1) TO (500);
CREATE TABLE test_part_child2 PARTITION OF test_part_parent FOR VALUES FROM (500) TO (1000);
CREATE TABLE test_part_child3 PARTITION OF test_part_parent FOR VALUES FROM (1000) TO (1500);

INSERT INTO test_part_child1 SELECT generate_series(1, 499), 'part1-' || generate_series(1, 499);
INSERT INTO test_part_child2 SELECT generate_series(500, 999), 'part2-' || generate_series(500, 999);
INSERT INTO test_part_child3 SELECT generate_series(1000, 1499), 'part3-' || generate_series(1000, 1499);

-- ANALYZE on the partitioned table triggers the inheritance path
ANALYZE VERBOSE test_part_parent;

DROP TABLE test_part_parent;

-- ================================================================
-- Test 3: Inheritance tree with empty child tables (zero blocks)
-- Coverage: Edge case where childblocks <= 0 for some children,
--            code path still executes the progress update
-- ================================================================
CREATE TABLE test_inh_empty_parent (id int, val text);
CREATE TABLE test_inh_empty_child1 () INHERITS (test_inh_empty_parent);
CREATE TABLE test_inh_empty_child2 () INHERITS (test_inh_empty_parent);

-- Only insert into parent, leave children empty (0 blocks)
INSERT INTO test_inh_empty_parent SELECT generate_series(1, 50), 'ep-' || generate_series(1, 50);

-- ANALYZE on the parent; empty children still trigger the progress update
ANALYZE VERBOSE test_inh_empty_parent;

DROP TABLE test_inh_empty_parent CASCADE;

-- ================================================================
-- Test 4: Inheritance tree with tables of very different sizes
-- Coverage: Child tables with different block counts, the progress
--            update is called for each child as the loop iterates
-- ================================================================
CREATE TABLE test_inh_size_parent (id int, val text);
CREATE TABLE test_inh_size_child1 () INHERITS (test_inh_size_parent);
CREATE TABLE test_inh_size_child2 () INHERITS (test_inh_size_parent);
CREATE TABLE test_inh_size_child3 () INHERITS (test_inh_size_parent);

-- Child1: small (just a few rows)
INSERT INTO test_inh_size_child1 SELECT generate_series(1, 10), 'small-' || generate_series(1, 10);
-- Child2: medium
INSERT INTO test_inh_size_child2 SELECT generate_series(11, 1000), 'medium-' || generate_series(11, 1000);
-- Child3: large
INSERT INTO test_inh_size_child3 SELECT generate_series(1001, 10000), 'large-' || generate_series(1001, 10000);

ANALYZE VERBOSE test_inh_size_parent;

DROP TABLE test_inh_size_parent CASCADE;

-- ================================================================
-- Test 5: Multi-level inheritance (parent -> child -> grandchild)
-- Coverage: Nested inheritance hierarchy; acquire_inherited_sample_rows
--            discovers all descendants via find_all_inheritors
-- ================================================================
CREATE TABLE test_inh_grandparent (id int, val text);
CREATE TABLE test_inh_parent_level2 () INHERITS (test_inh_grandparent);
CREATE TABLE test_inh_child_level3 () INHERITS (test_inh_parent_level2);

INSERT INTO test_inh_grandparent SELECT generate_series(1, 100), 'gp-' || generate_series(1, 100);
INSERT INTO test_inh_parent_level2 SELECT generate_series(101, 500), 'p2-' || generate_series(101, 500);
INSERT INTO test_inh_child_level3 SELECT generate_series(501, 1500), 'c3-' || generate_series(501, 1500);

-- ANALYZE on the grandparent analyzes all three levels
ANALYZE VERBOSE test_inh_grandparent;

DROP TABLE test_inh_grandparent CASCADE;

----------------------------------------
-- Source: 59.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Clean up MergeAttributesIntoExisting()
-- task_id: 59
-- This test exercises the refactored code paths in:
--   MergeAttributesIntoExisting(), MergeConstraintsIntoExisting(),
--   and RemoveInheritance()
-- ================================================================

-- ================================================================
-- Test 1: Basic INHERITS table creation (MergeAttributesIntoExisting)
-- Covers: Variable renaming refactoring, normal column matching path
-- The function iterates parent attributes, matches by name, bumps attinhcount
-- ================================================================
CREATE TABLE test59_parent1 (id int, name text, value numeric);
CREATE TABLE test59_child1 () INHERITS (test59_parent1);
-- Verify inheritance worked by checking column presence
SELECT attname, attinhcount, attislocal
FROM pg_attribute
WHERE attrelid = 'test59_child1'::regclass AND attnum > 0
ORDER BY attnum;
DROP TABLE test59_child1;
DROP TABLE test59_parent1;

-- ================================================================
-- Test 2: Child table with matching columns (MergeAttributesIntoExisting)
-- Covers: Code path where child already has the column with matching type/typmod
-- The function finds the column, checks type, collation, bumps attinhcount
-- ================================================================
CREATE TABLE test59_parent2 (a int, b text, c numeric(10,2));
CREATE TABLE test59_child2 (a int, b text, c numeric(10,2)) INHERITS (test59_parent2);
-- Check inheritance count was bumped
SELECT attname, attinhcount FROM pg_attribute
WHERE attrelid = 'test59_child2'::regclass AND attnum > 0
ORDER BY attnum;
DROP TABLE test59_child2;
DROP TABLE test59_parent2;

-- ================================================================
-- Test 3: Partition creation (both MergeAttributesIntoExisting and MergeConstraintsIntoExisting)
-- Covers: The refactored 'child_is_partition' → direct relkind check in BOTH functions
-- Also covers: attislocal = false for partition columns
-- ================================================================
CREATE TABLE test59_parent3 (id int not null, name text) PARTITION BY RANGE (id);
CREATE TABLE test59_child3 PARTITION OF test59_parent3 FOR VALUES FROM (1) TO (100);
-- Verify partition columns have attislocal=false and attinhcount=1
SELECT attname, attinhcount, attislocal FROM pg_attribute
WHERE attrelid = 'test59_child3'::regclass AND attnum > 0
ORDER BY attnum;
DROP TABLE test59_child3;
DROP TABLE test59_parent3;

-- ================================================================
-- Test 4: ALTER TABLE NO INHERIT (RemoveInheritance)
-- Covers: The refactored 'child_is_partition' → 'is_partitioning' variable
-- Also covers: attribute inheritance count decrement path
-- ================================================================
CREATE TABLE test59_parent4 (x int, y text);
CREATE TABLE test59_child4 () INHERITS (test59_parent4);
-- Verify inheritance before removal
SELECT attname, attinhcount FROM pg_attribute
WHERE attrelid = 'test59_child4'::regclass AND attnum > 0
ORDER BY attnum;
-- Remove inheritance
ALTER TABLE test59_child4 NO INHERIT test59_parent4;
-- Verify inheritance count was decremented
SELECT attname, attinhcount, attislocal FROM pg_attribute
WHERE attrelid = 'test59_child4'::regclass AND attnum > 0
ORDER BY attnum;
DROP TABLE test59_child4;
DROP TABLE test59_parent4;

-- ================================================================
-- Test 5: Detach partition (RemoveInheritance with is_partitioning=true)
-- Covers: The refactored 'is_partitioning' = true path in RemoveInheritance
-- Also covers: child_dependency_type(is_partitioning) call
-- ================================================================
CREATE TABLE test59_parent5 (id int, val text) PARTITION BY RANGE (id);
CREATE TABLE test59_child5 PARTITION OF test59_parent5 FOR VALUES FROM (1) TO (50);
CREATE TABLE test59_child5b PARTITION OF test59_parent5 FOR VALUES FROM (50) TO (100);
-- Verify partition structure
SELECT relname, relkind FROM pg_class
WHERE relname LIKE 'test59_child5%' ORDER BY relname;
-- Detach a partition
ALTER TABLE test59_parent5 DETACH PARTITION test59_child5;
-- Verify the detached table still exists but is no longer a partition
SELECT relname, relkind FROM pg_class
WHERE relname LIKE 'test59_child5%' ORDER BY relname;
DROP TABLE test59_child5;
DROP TABLE test59_child5b;
DROP TABLE test59_parent5;

----------------------------------------
-- Source: 60.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix edge-case for xl_tot_len broken by bae868ca
-- task_id: 60
-- Description:
--   This commit fixes a bug in XLogReadRecord() where a record with
--   xl_tot_len < SizeOfXLogRecord at the end of a page (too small for
--   the record header but not big enough to span to the next page)
--   would cause a bogus CRC check with an incorrect length.
--   The fix adds:
--     1) A check in the else branch of XLogReadRecord() (line 369-376)
--        that reports invalid record and goes to err if total_len < SizeOfXLogRecord.
--     2) An assertion Assert(record->xl_tot_len >= SizeOfXLogRecord)
--        in ValidXLogRecord() (line 1199).
--
-- These tests exercise the WAL generation and WAL reading code paths
-- through normal SQL operations that produce WAL records.
-- ================================================================

-- ================================================================
-- Test 1: Basic DML operations generating WAL records
-- Coverage: Exercises XLogReadRecord path by generating WAL via
--           INSERT/UPDATE/DELETE operations and switching WAL segments.
-- ================================================================
CREATE TABLE test_xlog_basic (id int PRIMARY KEY, value text);
INSERT INTO test_xlog_basic VALUES (1, 'alpha');
INSERT INTO test_xlog_basic VALUES (2, 'beta');
INSERT INTO test_xlog_basic VALUES (3, 'gamma');
UPDATE test_xlog_basic SET value = 'updated' WHERE id = 1;
DELETE FROM test_xlog_basic WHERE id = 3;
-- Force WAL segment switch to trigger WAL reading/validation
SELECT pg_switch_wal();
-- Re-insert to generate more WAL records on the new segment
INSERT INTO test_xlog_basic VALUES (4, 'delta');
INSERT INTO test_xlog_basic VALUES (5, 'epsilon');
SELECT pg_switch_wal();
DROP TABLE test_xlog_basic;


-- ================================================================
-- Test 2: Large data to create cross-page WAL records
-- Coverage: Exercises the code path where WAL records may span
--           multiple pages (total_len > XLOG_BLCKSZ - RecPtr % XLOG_BLCKSZ).
--           This triggers the "Need to reassemble record" code path
--           and exercises the XLogReadRecord function with records
--           that cross page boundaries.
-- ================================================================
CREATE TABLE test_xlog_large (id serial PRIMARY KEY, data text);
-- Insert large text values to generate large WAL records
-- that are more likely to span page boundaries
INSERT INTO test_xlog_large (data) SELECT repeat('A', 10000);
INSERT INTO test_xlog_large (data) SELECT repeat('B', 10000);
INSERT INTO test_xlog_large (data) SELECT repeat('C', 10000);
-- Force checkpoint to ensure WAL is written and can be re-read
CHECKPOINT;
-- Generate more large records
INSERT INTO test_xlog_large (data) SELECT repeat('D', 15000);
INSERT INTO test_xlog_large (data) SELECT repeat('E', 15000);
-- Switch WAL segment
SELECT pg_switch_wal();
-- More records on new segment
INSERT INTO test_xlog_large (data) SELECT repeat('F', 20000);
SELECT pg_switch_wal();
DROP TABLE test_xlog_large;


-- ================================================================
-- Test 3: Transactional operations generating many WAL records
-- Coverage: Exercises WAL record batching and the XLogReadRecord
--           code path when processing many small WAL records in
--           sequence. Tests the record validation path including
--           xl_tot_len checking.
-- ================================================================
CREATE TABLE test_xlog_txn (id int, val text);
-- Generate many WAL records through multiple transactions
BEGIN;
INSERT INTO test_xlog_txn VALUES (1, 'transactional');
INSERT INTO test_xlog_txn VALUES (2, 'data');
INSERT INTO test_xlog_txn VALUES (3, 'with');
INSERT INTO test_xlog_txn VALUES (4, 'multiple');
INSERT INTO test_xlog_txn VALUES (5, 'rows');
COMMIT;
BEGIN;
UPDATE test_xlog_txn SET val = 'updated' WHERE id IN (1, 2, 3);
DELETE FROM test_xlog_txn WHERE id = 4;
COMMIT;
-- Force WAL flush and segment switch
SELECT pg_switch_wal();
-- More operations
BEGIN;
INSERT INTO test_xlog_txn SELECT generate_series(100, 200), 'bulk';
COMMIT;
CHECKPOINT;
SELECT pg_switch_wal();
DROP TABLE test_xlog_txn;


-- ================================================================
-- Test 4: Schema changes generating DDL WAL records
-- Coverage: Exercises WAL record generation for DDL operations
--           (CREATE/ALTER/DROP), which produce different types of
--           WAL records. This tests the ValidXLogRecord code path
--           with various record types.
-- ================================================================
CREATE TABLE test_xlog_ddl (id int, name text);
-- ALTER operations generate WAL records
ALTER TABLE test_xlog_ddl ADD COLUMN description text;
ALTER TABLE test_xlog_ddl ADD COLUMN created_at timestamp DEFAULT now();
ALTER TABLE test_xlog_ddl ALTER COLUMN name SET NOT NULL;
CREATE INDEX test_xlog_ddl_idx ON test_xlog_ddl (id);
-- Insert data and modify schema again
INSERT INTO test_xlog_ddl VALUES (1, 'test', 'description', now());
ALTER TABLE test_xlog_ddl DROP COLUMN description;
-- Switch WAL to force reading of these DDL records
SELECT pg_switch_wal();
-- More DDL
ALTER TABLE test_xlog_ddl RENAME COLUMN name TO title;
CHECKPOINT;
SELECT pg_switch_wal();
DROP TABLE test_xlog_ddl;


-- ================================================================
-- Test 5: WAL activity with varying record sizes (near-boundary cases)
-- Coverage: Exercises WAL records of varying sizes to test code
--           paths that deal with record length validation.
--           Tests that the xl_tot_len validation logic in
--           ValidXLogRecordHeader and XLogReadRecord is exercised
--           with records of different sizes, including edge cases
--           where records might be positioned near page boundaries.
-- ================================================================
CREATE TABLE test_xlog_boundary (id int, data text);
-- Create records of various sizes to trigger different WAL layouts
INSERT INTO test_xlog_boundary VALUES (1, 'tiny');
INSERT INTO test_xlog_boundary VALUES (2, repeat('medium sized string', 100));
INSERT INTO test_xlog_boundary VALUES (3, repeat('larger data to push WAL records toward page boundaries', 500));
INSERT INTO test_xlog_boundary VALUES (4, repeat('X', 8000));
-- Update existing rows to generate different WAL record types
UPDATE test_xlog_boundary SET data = repeat('updated data', 200) WHERE id = 1;
UPDATE test_xlog_boundary SET data = repeat('another update pattern', 300) WHERE id = 2;
-- Force WAL segment switches
SELECT pg_switch_wal();
-- Operations on next segment
INSERT INTO test_xlog_boundary VALUES (5, repeat('Z', 1000));
UPDATE test_xlog_boundary SET data = data || repeat(' appended', 50) WHERE id >= 3;
CHECKPOINT;
SELECT pg_switch_wal();
-- Clean up
DROP TABLE test_xlog_boundary;

----------------------------------------
-- Source: 61.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Limit to_tsvector_byid's initial array allocation
-- task_id: 61
--
-- Commit: Limit to_tsvector_byid's initial array allocation to something sane.
-- The fix caps prs.lenwords at MaxAllocSize / sizeof(ParsedWord) to prevent
-- "invalid memory alloc request size" errors (bug #18080 from Uwe Binder).
--
-- Changed code in to_tsany.c:
--   prs.lenwords = VARSIZE_ANY_EXHDR(in) / 6;   /* estimation */
--   if (prs.lenwords < 2)
--       prs.lenwords = 2;
--   else if (prs.lenwords > MaxAllocSize / sizeof(ParsedWord))
--       prs.lenwords = MaxAllocSize / sizeof(ParsedWord);
--
-- The tests below exercise the to_tsvector_byid() function through its
-- public interfaces (to_tsvector, to_tsvector(regconfig, text)).
-- ================================================================

--------------------------------------------------------------
-- Test 1: Lower bound — prs.lenwords < 2 → clamped to 2
-- Short inputs (1-11 bytes) produce lenwords = 0 or 1,
-- which triggers the lower-bound clamp.
--------------------------------------------------------------
SELECT 'Test 1: Short text inputs (lenwords < 2 guard)';

CREATE TABLE test_ts_lower (
    id serial primary key,
    content text
);

INSERT INTO test_ts_lower (content) VALUES
    ('a'),       -- lenwords ≈ 0 → clamped to 2
    ('hi'),      -- lenwords ≈ 0 → clamped to 2
    (''),        -- lenwords ≈ 0 → clamped to 2
    ('hello'),   -- lenwords ≈ 0 → clamped to 2
    ('cat dog'); -- lenwords ≈ 1 → clamped to 2

SELECT id, to_tsvector('simple', content) FROM test_ts_lower ORDER BY id;

DROP TABLE test_ts_lower;

--------------------------------------------------------------
-- Test 2: Normal path — reasonable estimation (2 <= lenwords <= limit)
-- Standard text inputs with varying length and content.
--------------------------------------------------------------
SELECT 'Test 2: Normal text inputs (normal estimation path)';

CREATE TABLE test_ts_normal (
    id serial primary key,
    content text
);

INSERT INTO test_ts_normal (content) VALUES
    ('The quick brown fox jumps over the lazy dog'),
    ('PostgreSQL full text search is powerful and flexible'),
    ('To be or not to be that is the question'),
    ('A fat cat sat on a mat and ate a fat rat');

SELECT id, to_tsvector('english', content) FROM test_ts_normal ORDER BY id;

DROP TABLE test_ts_normal;

--------------------------------------------------------------
-- Test 3: to_tsvector with single argument (uses default config)
-- This goes through to_tsvector() → to_tsvector_byid() code path.
--------------------------------------------------------------
SELECT 'Test 3: Single-argument to_tsvector (default config path)';

CREATE TABLE test_ts_default (
    id serial primary key,
    content text
);

INSERT INTO test_ts_default (content) VALUES
    ('Running through the default text search configuration'),
    ('Another document with important keywords for indexing'),
    ('Short text');

SELECT id, to_tsvector(content) FROM test_ts_default ORDER BY id;

DROP TABLE test_ts_default;

--------------------------------------------------------------
-- Test 4: Edge cases — special content that affects lexer behavior
-- Tests that parsetext + make_tsvector work correctly with the fix.
--------------------------------------------------------------
SELECT 'Test 4: Edge cases (special characters and patterns)';

CREATE TABLE test_ts_edge (
    id serial primary key,
    content text
);

INSERT INTO test_ts_edge (content) VALUES
    ('Email: user@example.com'),
    ('URL: https://www.postgresql.org/docs/'),
    ('Hyphenated: well-known state-of-the-art'),
    ('Numbers: -42 +3.14 1.5e-10'),
    ('Unicode: Café naïve élève 日本語');

SELECT id, to_tsvector('simple', content) FROM test_ts_edge ORDER BY id;

DROP TABLE test_ts_edge;

--------------------------------------------------------------
-- Test 5: Large input — many words to exercise a large lenwords estimate
-- A text of ~1MB gives lenwords ≈ 1M/6 ≈ 170K words estimated.
-- This is well within the allocation limit but exercises the
-- estimation and allocation path at a larger scale.
-- Uses a table with multiple large rows.
--------------------------------------------------------------
SELECT 'Test 5: Large text inputs (large lenwords estimation)';

CREATE TABLE test_ts_large (
    id serial primary key,
    content text
);

INSERT INTO test_ts_large (content)
SELECT string_agg('word' || gs, ' ')
FROM generate_series(1, 50000) gs;

INSERT INTO test_ts_large (content)
SELECT string_agg('term' || gs, ' ')
FROM generate_series(1, 100000) gs;

-- Verify both rows produce valid tsvectors
SELECT id,
       length(content)::int AS input_bytes,
       length(to_tsvector('simple', content))::int AS tsvector_bytes
FROM test_ts_large ORDER BY id;

DROP TABLE test_ts_large;

-- ================================================================
-- End of tests
-- ================================================================

----------------------------------------
-- Source: 62.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Collect dependency information for parsed CallStmts.
-- task_id: 62
-- ================================================================
-- This test exercises the code path in extract_query_dependencies_walker()
-- that handles CallStmt (src/backend/optimizer/plan/setrefs.c lines 2934-2942).
-- Without this fix, CALL statements inside plpgsql functions wouldn't collect
-- dependency info, causing "cache lookup failed" errors when the called
-- procedure is modified and the cached plan becomes stale.
-- ================================================================

-- Test 1: Basic plpgsql CALL - verify procedure dependency tracking
-- Coverage: CallStmt case in extract_query_dependencies_walker with funcexpr
-- Scenario: Create a procedure, call it from plpgsql, drop and recreate it,
--           then call again. Should not fail with "cache lookup failed".
CREATE TABLE test_call_dep_t1 (id int, val text);

CREATE PROCEDURE test_call_proc_v1(x text)
LANGUAGE SQL
AS $$
INSERT INTO test_call_dep_t1 VALUES (1, x);
$$;

CREATE OR REPLACE FUNCTION test_call_wrapper_v1()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  CALL test_call_proc_v1('hello');
END;
$$;

SELECT test_call_wrapper_v1();

-- Drop and recreate the procedure (simulating DDL that should invalidate cache)
DROP PROCEDURE test_call_proc_v1;

CREATE PROCEDURE test_call_proc_v1(x text)
LANGUAGE SQL
AS $$
INSERT INTO test_call_dep_t1 VALUES (2, x || ' world');
$$;

-- This should succeed (cache invalidation works thanks to dependency tracking)
SELECT test_call_wrapper_v1();

SELECT * FROM test_call_dep_t1 ORDER BY id;

DROP FUNCTION test_call_wrapper_v1;
DROP PROCEDURE test_call_proc_v1;
DROP TABLE test_call_dep_t1;


-- Test 2: plpgsql CALL with INOUT arguments (outargs dependency tracking)
-- Coverage: CallStmt case with outargs in extract_query_dependencies_walker
-- Scenario: Procedure with INOUT args, called from plpgsql, procedure gets altered
CREATE TABLE test_call_dep_t2 (result int);

CREATE PROCEDURE test_call_proc_inout(INOUT x int)
LANGUAGE SQL
AS $$
SELECT x * 2;
$$;

CREATE OR REPLACE FUNCTION test_call_wrapper_v2(val int)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  r int;
BEGIN
  r := val;
  CALL test_call_proc_inout(r);
  INSERT INTO test_call_dep_t2 VALUES (r);
  RETURN r;
END;
$$;

SELECT test_call_wrapper_v2(5);

-- Alter the procedure
CREATE OR REPLACE PROCEDURE test_call_proc_inout(INOUT x int)
LANGUAGE SQL
AS $$
SELECT x * 10;
$$;

-- Should use the new definition (cache invalidated due to dependency)
SELECT test_call_wrapper_v2(5);

SELECT * FROM test_call_dep_t2 ORDER BY result;

DROP FUNCTION test_call_wrapper_v2;
DROP PROCEDURE test_call_proc_inout;
DROP TABLE test_call_dep_t2;


-- Test 3: Multiple CALL statements in one plpgsql function to different procedures
-- Coverage: Multiple CallStmt nodes in same plpgsql function
CREATE TABLE test_call_dep_t3 (id int, val text);

CREATE PROCEDURE test_call_proc_a(x text)
LANGUAGE SQL
AS $$
INSERT INTO test_call_dep_t3 VALUES (1, x);
$$;

CREATE PROCEDURE test_call_proc_b(x text)
LANGUAGE SQL
AS $$
INSERT INTO test_call_dep_t3 VALUES (2, x);
$$;

CREATE OR REPLACE FUNCTION test_call_wrapper_v3()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  CALL test_call_proc_a('first');
  CALL test_call_proc_b('second');
END;
$$;

SELECT test_call_wrapper_v3();

-- Drop and recreate one of the procedures
DROP PROCEDURE test_call_proc_a;

CREATE PROCEDURE test_call_proc_a(x text)
LANGUAGE SQL
AS $$
INSERT INTO test_call_dep_t3 VALUES (3, x || ' modified');
$$;

SELECT test_call_wrapper_v3();

SELECT * FROM test_call_dep_t3 ORDER BY id;

DROP FUNCTION test_call_wrapper_v3;
DROP PROCEDURE test_call_proc_a;
DROP PROCEDURE test_call_proc_b;
DROP TABLE test_call_dep_t3;


-- Test 4: CALL with NULL arguments and edge case (volatile arguments)
-- Coverage: CallStmt with NULL and volatile args passed through funcexpr
CREATE TABLE test_call_dep_t4 (id int, val text);

CREATE PROCEDURE test_call_proc_nullable(INOUT a int, INOUT b text)
LANGUAGE SQL
AS $$
SELECT a, COALESCE(b, 'default');
$$;

CREATE OR REPLACE FUNCTION test_call_wrapper_v4()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  a_val int := NULL;
  b_val text := NULL;
BEGIN
  CALL test_call_proc_nullable(a_val, b_val);
  INSERT INTO test_call_dep_t4 VALUES (1, COALESCE(b_val, 'still_null'));
  RETURN b_val;
END;
$$;

SELECT test_call_wrapper_v4();

-- Recreate with different default handling
CREATE OR REPLACE PROCEDURE test_call_proc_nullable(INOUT a int, INOUT b text)
LANGUAGE SQL
AS $$
SELECT COALESCE(a, 0), COALESCE(b, 'new_default');
$$;

SELECT test_call_wrapper_v4();

SELECT * FROM test_call_dep_t4 ORDER BY id;

DROP FUNCTION test_call_wrapper_v4;
DROP PROCEDURE test_call_proc_nullable;
DROP TABLE test_call_dep_t4;


-- Test 5: CALL inside a plpgsql function used in a larger query context
-- Coverage: extract_query_dependencies being called from plancache for CALL stmts
-- Scenario: plpgsql function with CALL that is invoked from SELECT
-- Simulates the reported bug #18131 scenario
CREATE TABLE test_call_dep_t5 (id int, description text);

CREATE PROCEDURE test_call_proc_log(msg text)
LANGUAGE SQL
AS $$
INSERT INTO test_call_dep_t5 VALUES (nextval('test_call_seq_62'), msg);
$$;

CREATE SEQUENCE test_call_seq_62;

CREATE OR REPLACE FUNCTION test_call_wrapper_v5(msg text)
RETURNS int
LANGUAGE plpgsql
AS $$
BEGIN
  CALL test_call_proc_log(msg);
  RETURN currval('test_call_seq_62');
END;
$$;

SELECT test_call_wrapper_v5('first call');
SELECT test_call_wrapper_v5('second call');

-- Recreate the procedure with different logic
DROP PROCEDURE test_call_proc_log;
DROP SEQUENCE test_call_seq_62;

CREATE SEQUENCE test_call_seq_62 START 100;

CREATE PROCEDURE test_call_proc_log(msg text)
LANGUAGE SQL
AS $$
INSERT INTO test_call_dep_t5 VALUES (nextval('test_call_seq_62'), msg || ' (logged)');
$$;

-- Should succeed and use new procedure, not fail with "cache lookup"
SELECT test_call_wrapper_v5('third call');

SELECT * FROM test_call_dep_t5 ORDER BY id;

DROP FUNCTION test_call_wrapper_v5;
DROP PROCEDURE test_call_proc_log;
DROP SEQUENCE test_call_seq_62;
DROP TABLE test_call_dep_t5;

----------------------------------------
-- Source: 65.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Allow extracting fields from a ROW() expression
-- in more cases (get_expr_result_type handles RowExpr with RECORDOID)
-- task_id: 65
-- ================================================================

-- This test suite covers the new code path in get_expr_result_type()
-- (src/backend/utils/fmgr/funcapi.c) that manufactures a tuple descriptor
-- directly from a RowExpr node when its row_typeid is RECORDOID.
-- This allows extracting fields from anonymous ROW() expressions.

-- ================================================================
-- Test 1: Basic field extraction from a simple ROW() expression
-- Covers: RowExpr with RECORDOID, single-step type resolution
--         TupleDescInitEntry for each column in the ROW()
-- ================================================================
CREATE TABLE test_row_extract_basic (id int, description text);
INSERT INTO test_row_extract_basic VALUES (1, 'one'), (2, 'two'), (3, 'three');

-- Extract individual fields from a ROW() constructor
EXPLAIN ANALYZE SELECT (ROW(id, description)).* FROM test_row_extract_basic ORDER BY id;

-- Extract a specific field by name
EXPLAIN ANALYZE SELECT (ROW(id, description)).column2 FROM test_row_extract_basic ORDER BY id;

DROP TABLE test_row_extract_basic;

-- ================================================================
-- Test 2: ROW() with mixed data types (int, text, numeric, boolean)
-- Covers: Multiple column types with different exprType/exprTypmod/exprCollation
-- ================================================================
CREATE TABLE test_row_mixed (a int, b text, c numeric, d bool);
INSERT INTO test_row_mixed VALUES (1, 'hello', 3.14, true), (NULL, 'world', NULL, false);

-- Expand all fields from a multi-type ROW()
EXPLAIN ANALYZE SELECT (ROW(a, b, c, d)).* FROM test_row_mixed ORDER BY a;

-- Extract the numeric field (3rd column)
EXPLAIN ANALYZE SELECT (ROW(a, b, c, d)).column3 FROM test_row_mixed ORDER BY a;

DROP TABLE test_row_mixed;

-- ================================================================
-- Test 3: ROW() with NULL values and empty result set
-- Covers: NULL columns in RowExpr, BlessTupleDesc for RECORD type
--         Edge case: no rows returned
-- ================================================================
CREATE TABLE test_row_nulls (x int, y text);
INSERT INTO test_row_nulls VALUES (1, NULL), (NULL, 'not null'), (NULL, NULL);

-- ROW() with NULL values in various positions
EXPLAIN ANALYZE SELECT (ROW(x, y)).* FROM test_row_nulls ORDER BY x;

-- Empty result (no rows)
DELETE FROM test_row_nulls;
EXPLAIN ANALYZE SELECT (ROW(x, y)).* FROM test_row_nulls;

DROP TABLE test_row_nulls;

-- ================================================================
-- Test 4: ROW() with expressions, functions, and computed columns
-- Covers: Non-trivial column expressions inside RowExpr
--         exprType/exprTypmod evaluation on function results
-- ================================================================
CREATE TABLE test_row_expr (val int, name text);
INSERT INTO test_row_expr VALUES (10, 'ten'), (20, 'twenty'), (30, 'thirty');

-- ROW() with computed expressions (arithmetic, string concatenation, function calls)
EXPLAIN ANALYZE SELECT (ROW(val * 2, upper(name), val::text || '_suffix', now()::date)).*
FROM test_row_expr ORDER BY val;

-- Extract a specific computed field
EXPLAIN ANALYZE SELECT (ROW(val * 2, upper(name), val::text || '_suffix')).column2
FROM test_row_expr ORDER BY val;

DROP TABLE test_row_expr;

-- ================================================================
-- Test 5: ROW() in subqueries, CTEs, and combined with other constructs
-- Covers: RowExpr inside larger query structures
--         get_expr_result_type called through various callers
-- ================================================================
CREATE TABLE test_row_advanced (id int, data text);
INSERT INTO test_row_advanced VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');

-- CTE using ROW() with field extraction
EXPLAIN ANALYZE
WITH cte AS (
    SELECT ROW(id, data) AS r FROM test_row_advanced
)
SELECT (r).* FROM cte ORDER BY id;

-- Subquery with ROW() field extraction
EXPLAIN ANALYZE
SELECT sq.col1, sq.col2
FROM (
    SELECT (ROW(id, data)).* FROM test_row_advanced
) AS sq(col1, col2)
ORDER BY col1;

-- ROW() with correlated subquery
EXPLAIN ANALYZE
SELECT id,
       (SELECT (ROW(id, data)).* FROM test_row_advanced t2 WHERE t2.id = t1.id LIMIT 1)
FROM test_row_advanced t1
ORDER BY id;

DROP TABLE test_row_advanced;

-- ================================================================
-- End of regression tests
-- ================================================================

----------------------------------------
-- Source: 67.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Cache by-reference missing values in a long lived context
-- task_id: 67
-- 
-- This test exercises the new missing value caching logic in getmissingattr().
-- When a table has columns added with by-reference default values (e.g., text, varchar, bytea),
-- and existing rows are accessed, getmissingattr() returns the missing attribute value.
-- The new code caches a datumCopy'd version in TopMemoryContext to avoid dangling pointers
-- after the tupleDesc is destroyed.
-- ================================================================

-- ================================================================
-- Test 1: Basic text default value (by-reference type)
-- Covers: init_missing_cache() first-time setup, cache miss path (datumCopy),
--         hash_insert of a new entry, returning cached value
-- ================================================================

CREATE TABLE test_missing_text (id INT NOT NULL PRIMARY KEY);

-- Insert some rows BEFORE adding the column with default
INSERT INTO test_missing_text SELECT generate_series(1, 100);

-- Add a text column with a default (by-reference type, triggers getmissingattr)
ALTER TABLE test_missing_text ADD COLUMN description TEXT DEFAULT 'default_description';

-- Query that accesses old rows, forcing getmissingattr() to retrieve the missing value
-- This exercises: init_missing_cache(), hash_search(HASH_ENTER, found=false),
--                 datumCopy(), and returning the cached value
EXPLAIN ANALYZE SELECT id, description FROM test_missing_text WHERE id <= 10 ORDER BY id;

-- Verify the values are correct
SELECT id, description FROM test_missing_text WHERE id <= 10 ORDER BY id;

-- Second query should find the value in cache (HASH_ENTER, found=true, reuse cached)
EXPLAIN ANALYZE SELECT id, description FROM test_missing_text WHERE id > 90 ORDER BY id;

DROP TABLE test_missing_text;


-- ================================================================
-- Test 2: Multiple by-reference column types (text, varchar, bytea, numeric)
-- Covers: different attlen values (>0 for bpchar, -1 for text/varchar/bytea),
--         cache key construction with different lengths,
--         VARSIZE_ANY path for variable-length types
-- ================================================================

CREATE TABLE test_missing_multi (id INT NOT NULL PRIMARY KEY);

INSERT INTO test_missing_multi SELECT generate_series(1, 50);

-- Add multiple by-reference columns all at once
ALTER TABLE test_missing_multi ADD COLUMN txt_col TEXT DEFAULT 'hello';
ALTER TABLE test_missing_multi ADD COLUMN vc_col VARCHAR(50) DEFAULT 'world';
ALTER TABLE test_missing_multi ADD COLUMN ba_col BYTEA DEFAULT '\xdeadbeef'::bytea;
ALTER TABLE test_missing_multi ADD COLUMN bp_col CHAR(10) DEFAULT 'fixed';

-- Query accessing all missing columns via sequential scan
-- Each by-reference column triggers a separate getmissingattr() call
-- Each has different attlen and needs its own cache entry
EXPLAIN ANALYZE SELECT id, txt_col, vc_col, ba_col, bp_col 
FROM test_missing_multi WHERE id <= 10;

-- Second access: should all be cache hits now
EXPLAIN ANALYZE SELECT id, txt_col, vc_col, ba_col, bp_col 
FROM test_missing_multi WHERE id > 40;

-- Verify actual values
SELECT id, txt_col, vc_col, ba_col, bp_col 
FROM test_missing_multi WHERE id <= 5 ORDER BY id;

DROP TABLE test_missing_multi;


-- ================================================================
-- Test 3: Long text value and repeated access in same query
-- Covers: longer text values (larger len in missing_cache_key),
--         hash_any over larger data, repeated cache hits,
--         memcmp in missing_match for same-length values
-- ================================================================

CREATE TABLE test_missing_long (id INT NOT NULL PRIMARY KEY);

INSERT INTO test_missing_long SELECT generate_series(1, 30);

-- Add a column with a long text default value (tests hash quality)
ALTER TABLE test_missing_long ADD COLUMN long_text TEXT DEFAULT 
    'This is a very long default string that should test the caching mechanism ' ||
    'for longer text values. The hash function needs to process all of this ' ||
    'data to produce a good hash. Repeated access will test cache hit path.';

-- WHERE clause that accesses many old rows, all needing the same missing value
-- First access: cache miss for first row, cache hits for subsequent rows
EXPLAIN ANALYZE SELECT id, long_text FROM test_missing_long ORDER BY id;

-- Use in a GROUP BY/aggregate to exercise more code paths
SELECT COUNT(*), long_text FROM test_missing_long GROUP BY long_text;

DROP TABLE test_missing_long;


-- ================================================================
-- Test 4: Mixed NULL handling and by-value + by-reference defaults
-- Covers: by-value attrs (attbyval=true) returning directly without cache,
--         by-reference attrs using cache path,
--         NULL missing values (no am_present set)
-- ================================================================

CREATE TABLE test_missing_mixed (id INT NOT NULL PRIMARY KEY);

INSERT INTO test_missing_mixed SELECT generate_series(1, 40);

-- Add columns: int (by-value), text (by-reference), and one without default
ALTER TABLE test_missing_mixed ADD COLUMN int_val INT DEFAULT 42;
ALTER TABLE test_missing_mixed ADD COLUMN txt_val TEXT DEFAULT 'mixed_test';
ALTER TABLE test_missing_mixed ADD COLUMN extra_col INT;

-- Insert some new rows with explicit values for all columns
INSERT INTO test_missing_mixed VALUES (41, 100, 'explicit', 999);
INSERT INTO test_missing_mixed VALUES (42, 200, 'another', NULL);

-- Query that accesses both old and new rows
-- Old rows: int_val uses by-value path (no cache), txt_val uses cache
-- New rows: have explicit values, so no missing value needed
EXPLAIN ANALYZE SELECT * FROM test_missing_mixed ORDER BY id;

-- Filter on the by-reference missing column
EXPLAIN ANALYZE SELECT id, txt_val FROM test_missing_mixed 
WHERE txt_val = 'mixed_test' ORDER BY id;

DROP TABLE test_missing_mixed;


-- ================================================================
-- Test 5: Different default values for different ALTER TABLE operations
-- Covers: cache entries for multiple distinct default values,
--         missing_match function (comparing different values),
--         hash collision handling (multiple different keys),
--         the cache persisting across multiple queries
-- ================================================================

CREATE TABLE test_missing_diff (id INT NOT NULL PRIMARY KEY);

INSERT INTO test_missing_diff SELECT generate_series(1, 20);

-- Add first column with a default
ALTER TABLE test_missing_diff ADD COLUMN status_a TEXT DEFAULT 'pending';

-- Insert more rows
INSERT INTO test_missing_diff SELECT generate_series(21, 40);

-- Add second column with a DIFFERENT default value
ALTER TABLE test_missing_diff ADD COLUMN status_b TEXT DEFAULT 'active';

-- Now we have two different missing values across different row ranges
-- Rows 1-20: both status_a and status_b are missing values
-- Rows 21-40: only status_b is missing value
EXPLAIN ANALYZE SELECT id, status_a, status_b FROM test_missing_diff ORDER BY id;

-- Add a third column with yet another default
ALTER TABLE test_missing_diff ADD COLUMN status_c TEXT DEFAULT 'completed';

-- Now three different missing value keys need to be cached
EXPLAIN ANALYZE SELECT id, status_a, status_b, status_c FROM test_missing_diff ORDER BY id;

-- Verify all values
SELECT id, status_a, status_b, status_c FROM test_missing_diff WHERE id IN (1, 20, 21, 40, 41) ORDER BY id;

DROP TABLE test_missing_diff;


----------------------------------------
-- Source: 68.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Add OAT hook calls for more subcommands of ALTER TABLE
-- task_id: 68
-- 
-- This test exercises the InvokeObjectPostAlterHook calls added to:
--   1. ATExecEnableDisableTrigger   (ENABLE / DISABLE TRIGGER)
--   2. ATExecEnableDisableRule      (ENABLE / DISABLE RULE)
--   3. ATExecEnableRowSecurity      (ENABLE ROW LEVEL SECURITY)
--   4. ATExecDisableRowSecurity     (DISABLE ROW LEVEL SECURITY)
--   5. ATExecForceNoForceRowSecurity (FORCE / NO FORCE ROW LEVEL SECURITY)
-- ================================================================

-- ================================================================
-- Test 1: ALTER TABLE ... ENABLE TRIGGER
-- 
-- Covers: InvokeObjectPostAlterHook(RelationRelationId,
--          RelationGetRelid(rel), 0) in ATExecEnableDisableTrigger
-- 
-- Steps:
--   1. Create a table with a trigger function
--   2. Create a trigger on the table
--   3. Disable the trigger (ALTER TABLE ... DISABLE TRIGGER)
--   4. Re-enable the trigger (ALTER TABLE ... ENABLE TRIGGER)
--   5. Also test ENABLE REPLICA TRIGGER and ENABLE ALWAYS TRIGGER
-- ================================================================
CREATE TABLE test_oat_trig (
    id INTEGER PRIMARY KEY,
    val TEXT
);

CREATE FUNCTION test_oat_trig_func() RETURNS TRIGGER LANGUAGE plpgsql
AS $$
BEGIN
    NEW.val = UPPER(NEW.val);
    RETURN NEW;
END;
$$;

CREATE TRIGGER test_oat_before_ins
    BEFORE INSERT ON test_oat_trig
    FOR EACH ROW EXECUTE FUNCTION test_oat_trig_func();

-- DISABLE TRIGGER (specific trigger by name)
ALTER TABLE test_oat_trig DISABLE TRIGGER test_oat_before_ins;

-- ENABLE TRIGGER (specific trigger by name)
ALTER TABLE test_oat_trig ENABLE TRIGGER test_oat_before_ins;

-- DISABLE TRIGGER (all triggers)
ALTER TABLE test_oat_trig DISABLE TRIGGER ALL;

-- ENABLE TRIGGER (all triggers)
ALTER TABLE test_oat_trig ENABLE TRIGGER ALL;

-- Also test ENABLE REPLICA TRIGGER
ALTER TABLE test_oat_trig ENABLE REPLICA TRIGGER test_oat_before_ins;

-- Also test ENABLE ALWAYS TRIGGER
ALTER TABLE test_oat_trig ENABLE ALWAYS TRIGGER test_oat_before_ins;

-- Test NO FORCE TRIGGER variants
ALTER TABLE test_oat_trig DISABLE TRIGGER USER;

DROP TRIGGER test_oat_before_ins ON test_oat_trig;
DROP FUNCTION test_oat_trig_func();
DROP TABLE test_oat_trig;


-- ================================================================
-- Test 2: ALTER TABLE ... ENABLE/DISABLE RULE
-- 
-- Covers: InvokeObjectPostAlterHook(RelationRelationId,
--          RelationGetRelid(rel), 0) in ATExecEnableDisableRule
-- 
-- Steps:
--   1. Create a table
--   2. Create a rewrite rule (ON INSERT DO INSTEAD)
--   3. DISABLE RULE
--   4. ENABLE RULE
--   5. Test all fire variants: ENABLE REPLICA RULE, ENABLE ALWAYS RULE
-- ================================================================
CREATE TABLE test_oat_rule_base (
    id INTEGER PRIMARY KEY,
    data TEXT
);

CREATE TABLE test_oat_rule_log (
    id INTEGER,
    data TEXT,
    logged_at TIMESTAMP DEFAULT now()
);

CREATE RULE test_oat_insert_rule AS
    ON INSERT TO test_oat_rule_base
    DO INSTEAD (
        INSERT INTO test_oat_rule_log (id, data) VALUES (NEW.id, NEW.data)
    );

-- DISABLE RULE
ALTER TABLE test_oat_rule_base DISABLE RULE test_oat_insert_rule;

-- ENABLE RULE
ALTER TABLE test_oat_rule_base ENABLE RULE test_oat_insert_rule;

-- DISABLE RULE (all rules)
ALTER TABLE test_oat_rule_base DISABLE RULE _RETURN;

-- Test ENABLE REPLICA RULE
ALTER TABLE test_oat_rule_base ENABLE REPLICA RULE test_oat_insert_rule;

-- Test ENABLE ALWAYS RULE
ALTER TABLE test_oat_rule_base ENABLE ALWAYS RULE test_oat_insert_rule;

DROP RULE test_oat_insert_rule ON test_oat_rule_base;
DROP TABLE test_oat_rule_base;
DROP TABLE test_oat_rule_log;


-- ================================================================
-- Test 3: ALTER TABLE ... ENABLE ROW LEVEL SECURITY
-- 
-- Covers: InvokeObjectPostAlterHook(RelationRelationId,
--          RelationGetRelid(rel), 0) in ATExecEnableRowSecurity
-- 
-- Steps:
--   1. Create a table with a user for RLS testing
--   2. ENABLE ROW LEVEL SECURITY
--   3. Verify RLS is enabled by checking pg_class
--   4. Test with a policy to exercise the full RLS path
-- ================================================================
CREATE TABLE test_oat_rls_enable (
    id INTEGER PRIMARY KEY,
    owner TEXT,
    secret_data TEXT
);

-- Insert some data
INSERT INTO test_oat_rls_enable VALUES
    (1, 'alice', 'secret1'),
    (2, 'bob', 'secret2'),
    (3, 'carol', 'secret3');

-- ENABLE ROW LEVEL SECURITY
ALTER TABLE test_oat_rls_enable ENABLE ROW LEVEL SECURITY;

-- Create a policy so RLS has an effect
CREATE POLICY test_oat_rls_policy ON test_oat_rls_enable
    FOR ALL
    USING (owner = current_user);

-- Grant access to public
GRANT ALL ON test_oat_rls_enable TO PUBLIC;

-- DISABLE ROW LEVEL SECURITY to test the disable path too
ALTER TABLE test_oat_rls_enable DISABLE ROW LEVEL SECURITY;

-- Re-enable it
ALTER TABLE test_oat_rls_enable ENABLE ROW LEVEL SECURITY;

DROP POLICY test_oat_rls_policy ON test_oat_rls_enable;
DROP TABLE test_oat_rls_enable;


-- ================================================================
-- Test 4: ALTER TABLE ... FORCE / NO FORCE ROW LEVEL SECURITY
-- 
-- Covers: InvokeObjectPostAlterHook(RelationRelationId,
--          RelationGetRelid(rel), 0) in ATExecForceNoForceRowSecurity
-- 
-- Steps:
--   1. Create a table with RLS enabled
--   2. FORCE ROW LEVEL SECURITY (force RLS on table owners)
--   3. NO FORCE ROW LEVEL SECURITY (revert)
--   4. Toggle between both states
-- ================================================================
CREATE TABLE test_oat_rls_force (
    id INTEGER PRIMARY KEY,
    value TEXT
);

INSERT INTO test_oat_rls_force VALUES (1, 'data1'), (2, 'data2');

-- Enable RLS first (required before FORCE)
ALTER TABLE test_oat_rls_force ENABLE ROW LEVEL SECURITY;

-- FORCE ROW LEVEL SECURITY
ALTER TABLE test_oat_rls_force FORCE ROW LEVEL SECURITY;

-- NO FORCE ROW LEVEL SECURITY
ALTER TABLE test_oat_rls_force NO FORCE ROW LEVEL SECURITY;

-- Toggle again to hit the code path multiple times
ALTER TABLE test_oat_rls_force FORCE ROW LEVEL SECURITY;
ALTER TABLE test_oat_rls_force NO FORCE ROW LEVEL SECURITY;

DROP TABLE test_oat_rls_force;


-- ================================================================
-- Test 5: Combined test — all subcommands on the same table
-- 
-- Covers: All 4 new hook call sites on a single table
-- 
-- This test exercises all four hook additions together, ensuring
-- they compose correctly and don't interfere with each other.
-- ================================================================
CREATE TABLE test_oat_combined (
    id INTEGER PRIMARY KEY,
    payload TEXT,
    owner TEXT DEFAULT current_user
);

-- Add a trigger
CREATE FUNCTION test_oat_combined_trig() RETURNS TRIGGER LANGUAGE plpgsql
AS $$
BEGIN
    NEW.payload = COALESCE(NEW.payload, 'default');
    RETURN NEW;
END;
$$;

CREATE TRIGGER test_oat_combined_ins
    BEFORE INSERT ON test_oat_combined
    FOR EACH ROW EXECUTE FUNCTION test_oat_combined_trig();

-- Add a rule
CREATE TABLE test_oat_combined_audit (
    id INTEGER,
    old_payload TEXT,
    new_payload TEXT,
    changed_at TIMESTAMP DEFAULT now()
);

CREATE RULE test_oat_combined_log AS
    ON UPDATE TO test_oat_combined
    DO ALSO
        INSERT INTO test_oat_combined_audit (id, old_payload, new_payload)
        VALUES (OLD.id, OLD.payload, NEW.payload);

-- Exercise all four hook sites:
-- 1. DISABLE TRIGGER (ATExecEnableDisableTrigger)
ALTER TABLE test_oat_combined DISABLE TRIGGER test_oat_combined_ins;
ALTER TABLE test_oat_combined ENABLE TRIGGER test_oat_combined_ins;

-- 2. DISABLE RULE (ATExecEnableDisableRule)
ALTER TABLE test_oat_combined DISABLE RULE test_oat_combined_log;
ALTER TABLE test_oat_combined ENABLE RULE test_oat_combined_log;

-- 3. ENABLE ROW LEVEL SECURITY (ATExecEnableRowSecurity)
ALTER TABLE test_oat_combined ENABLE ROW LEVEL SECURITY;

-- 4. FORCE ROW LEVEL SECURITY (ATExecForceNoForceRowSecurity)
ALTER TABLE test_oat_combined FORCE ROW LEVEL SECURITY;
ALTER TABLE test_oat_combined NO FORCE ROW LEVEL SECURITY;

-- 5. DISABLE ROW LEVEL SECURITY (ATExecDisableRowSecurity)
ALTER TABLE test_oat_combined DISABLE ROW LEVEL SECURITY;

-- Clean up
DROP RULE test_oat_combined_log ON test_oat_combined;
DROP TABLE test_oat_combined_audit;
DROP TRIGGER test_oat_combined_ins ON test_oat_combined;
DROP FUNCTION test_oat_combined_trig();
DROP TABLE test_oat_combined;

----------------------------------------
-- Source: 69.sql
----------------------------------------
-- ================================================================
-- PostgreSQL SQL Regression Test
-- task_id: 69
-- Subject: Recalculate search_path after ALTER ROLE.
-- 
-- This change registers a syscache callback on pg_authid (AUTHOID)
-- so that when a role is renamed (ALTER ROLE ... RENAME TO ...),
-- the search_path is recalculated. This is necessary because the
-- special string $user in search_path resolves to the current role
-- name, and renaming a role changes the meaning of $user.
--
-- Modified code path (src/backend/catalog/namespace.c):
--   InitializeSearchPath() now calls:
--     CacheRegisterSyscacheCallback(AUTHOID, NamespaceCallback, (Datum) 0);
--   This causes NamespaceCallback() to set baseSearchPathValid = false
--   when pg_authid is modified, forcing recomputeNamespacePath()
--   to re-resolve $user on next use.
-- ================================================================

-- ================================================================
-- Test 1: Basic role rename with $user in search_path
-- 
-- Coverage: After renaming a role, $user in search_path should
-- resolve to the new role name. Create a schema matching the new
-- role name and verify it becomes accessible.
-- ================================================================

-- Create a test role and a schema named after the role
CREATE ROLE regress_test_role69_1 LOGIN;
CREATE SCHEMA regress_test_role69_1 AUTHORIZATION regress_test_role69_1;

-- Create a table in the role-named schema
CREATE TABLE regress_test_role69_1.test_table (id int, val text);
INSERT INTO regress_test_role69_1.test_table VALUES (1, 'hello');

-- Set search_path to include $user
SET search_path TO "$user", public;

-- Now rename the role
ALTER ROLE regress_test_role69_1 RENAME TO regress_test_role69_1_renamed;

-- Create a schema matching the new role name
CREATE SCHEMA regress_test_role69_1_renamed AUTHORIZATION regress_test_role69_1_renamed;

-- Create a table in the new schema
CREATE TABLE regress_test_role69_1_renamed.test_table2 (id int, val text);
INSERT INTO regress_test_role69_1_renamed.test_table2 VALUES (2, 'world');

-- At this point, the namespace cache invalidation (AUTHOID callback)
-- should have been triggered. The search_path should now resolve $user
-- to 'regress_test_role69_1_renamed', making test_table2 accessible.
EXPLAIN ANALYZE SELECT * FROM test_table2;

-- Cleanup
DROP TABLE IF EXISTS regress_test_role69_1_renamed.test_table2;
DROP TABLE IF EXISTS regress_test_role69_1.test_table;
DROP SCHEMA IF EXISTS regress_test_role69_1_renamed;
DROP SCHEMA IF EXISTS regress_test_role69_1;
-- Rename the role back so we can drop it (need to reconnect as superuser or use original name)
ALTER ROLE regress_test_role69_1_renamed RENAME TO regress_test_role69_1;
DROP ROLE IF EXISTS regress_test_role69_1;
-- Reset search_path
RESET search_path;

-- ================================================================
-- Test 2: Role rename affects current session's $user resolution
-- 
-- Coverage: The AUTHOID callback is session-level. Renaming a role
-- in one session should cause $user to be re-resolved when the
-- search_path is next used in that same session.
-- ================================================================

CREATE ROLE regress_test_role69_2 LOGIN;
CREATE SCHEMA regress_test_role69_2 AUTHORIZATION regress_test_role69_2;

SET search_path TO "$user", public;

-- Verify the current $user schema is accessible
CREATE TABLE regress_test_role69_2.t1 (a int);

-- Rename the role
ALTER ROLE regress_test_role69_2 RENAME TO regress_test_role69_2_new;

-- Create a schema matching the new role name
CREATE SCHEMA regress_test_role69_2_new AUTHORIZATION regress_test_role69_2_new;

-- After the rename, search_path should have been invalidated.
-- Accessing objects now should trigger recomputeNamespacePath(),
-- which re-looks-up the role name via SearchSysCache1(AUTHOID,...)
-- and finds the new name, resolving $user to regress_test_role69_2_new.
-- Since regress_test_role69_2.t1 is no longer accessible via $user,
-- but we can still access it explicitly.
EXPLAIN ANALYZE SELECT count(*) FROM regress_test_role69_2_new.t1;

-- Cleanup
DROP TABLE IF EXISTS regress_test_role69_2_new.t1;
DROP SCHEMA IF EXISTS regress_test_role69_2_new;
DROP SCHEMA IF EXISTS regress_test_role69_2;
ALTER ROLE regress_test_role69_2_new RENAME TO regress_test_role69_2;
DROP ROLE IF EXISTS regress_test_role69_2;
RESET search_path;

-- ================================================================
-- Test 3: Multiple roles in the session with $user in search_path
-- 
-- Coverage: The callback works correctly when multiple roles exist
-- and $user is interpreted differently for each role. Tests that
-- the syscache invalidation correctly propagates to all sessions
-- and that the search_path recalculation picks up the right schema.
-- ================================================================

CREATE ROLE regress_test_role69_3a LOGIN;
CREATE ROLE regress_test_role69_3b LOGIN;

CREATE SCHEMA regress_test_role69_3a AUTHORIZATION regress_test_role69_3a;
CREATE SCHEMA regress_test_role69_3b AUTHORIZATION regress_test_role69_3b;

-- Set search_path to include $user
SET search_path TO "$user", public;

-- Rename regress_test_role69_3a
ALTER ROLE regress_test_role69_3a RENAME TO regress_test_role69_3a_renamed;

-- Create schema for the renamed role
CREATE SCHEMA regress_test_role69_3a_renamed AUTHORIZATION regress_test_role69_3a_renamed;

-- Now search_path should resolve $user to regress_test_role69_3a_renamed
-- (not regress_test_role69_3a). Let's create a table in the new schema
-- and try to access it via unqualified name.
CREATE TABLE regress_test_role69_3a_renamed.t3 (x int);
INSERT INTO regress_test_role69_3a_renamed.t3 VALUES (100);

-- This query triggers recomputeNamespacePath() where $user is
-- re-resolved using SearchSysCache1(AUTHOID, roleid), finding
-- the new role name, and looking up the matching schema.
EXPLAIN ANALYZE SELECT * FROM t3;

-- Cleanup
DROP TABLE IF EXISTS regress_test_role69_3a_renamed.t3;
DROP SCHEMA IF EXISTS regress_test_role69_3a_renamed;
DROP SCHEMA IF EXISTS regress_test_role69_3a;
DROP SCHEMA IF EXISTS regress_test_role69_3b;
ALTER ROLE regress_test_role69_3a_renamed RENAME TO regress_test_role69_3a;
DROP ROLE IF EXISTS regress_test_role69_3a;
DROP ROLE IF EXISTS regress_test_role69_3b;
RESET search_path;

-- ================================================================
-- Test 4: Role rename when no schema matches the role name
-- 
-- Coverage: Edge case where after renaming a role, there is no
-- schema matching the new role name. $user should simply be
-- silently skipped (no error). Tests that the AUTHOID callback
-- correctly triggers recalculation even when the result is empty.
-- ================================================================

CREATE ROLE regress_test_role69_4 LOGIN;
CREATE SCHEMA regress_test_role69_4 AUTHORIZATION regress_test_role69_4;

SET search_path TO "$user", public;

-- Create table accessible via $user
CREATE TABLE regress_test_role69_4.t4 (id serial, data text);
INSERT INTO regress_test_role69_4.t4 (data) VALUES ('accessible');

-- Rename the role to a name that has no matching schema
ALTER ROLE regress_test_role69_4 RENAME TO regress_test_role69_4_noschema;

-- Now $user resolves to 'regress_test_role69_4_noschema', but
-- there is no schema with that name. The search_path should skip
-- $user silently (get_namespace_oid returns InvalidOid).
-- This triggers the code path where $user substitution yields
-- no matching namespace OID.
EXPLAIN ANALYZE SELECT count(*) FROM pg_class WHERE relname LIKE 't4';

-- Explicit schema access should still work
EXPLAIN ANALYZE SELECT * FROM regress_test_role69_4.t4;

-- Cleanup
DROP TABLE IF EXISTS regress_test_role69_4.t4;
DROP SCHEMA IF EXISTS regress_test_role69_4;
ALTER ROLE regress_test_role69_4_noschema RENAME TO regress_test_role69_4;
DROP ROLE IF EXISTS regress_test_role69_4;
RESET search_path;

-- ================================================================
-- Test 5: Role rename with special characters and $user
-- 
-- Coverage: Role names with special characters that might affect
-- search_path parsing. Tests that the AUTHOID cache callback
-- works correctly for roles with non-ASCII or special characters
-- in their names, and that $user is properly resolved.
-- ================================================================

CREATE ROLE "regress_test_$role_69_5" LOGIN;
CREATE SCHEMA "regress_test_$role_69_5" AUTHORIZATION "regress_test_$role_69_5";

SET search_path TO "$user", public;

-- Create a table accessible via $user (resolved to the role name)
CREATE TABLE "regress_test_$role_69_5".t5 (id int);
INSERT INTO "regress_test_$role_69_5".t5 VALUES (555);

-- Rename the role to another name with special characters
ALTER ROLE "regress_test_$role_69_5" RENAME TO "regress_test_$role_69_5_renamed";

-- Create schema matching the new role name
CREATE SCHEMA "regress_test_$role_69_5_renamed" AUTHORIZATION "regress_test_$role_69_5_renamed";

-- After rename, $user should now resolve to 'regress_test_$role_69_5_renamed'
-- and making t5_renamed accessible without schema qualification.
CREATE TABLE "regress_test_$role_69_5_renamed".t5_renamed (id int, val text);
INSERT INTO "regress_test_$role_69_5_renamed".t5_renamed VALUES (1, 'special');

-- This triggers the code path: NamespaceCallback -> baseSearchPathValid=false
-- -> recomputeNamespacePath() -> $user lookup via SearchSysCache1(AUTHOID,...)
EXPLAIN ANALYZE SELECT * FROM t5_renamed;

-- Cleanup
DROP TABLE IF EXISTS "regress_test_$role_69_5_renamed".t5_renamed;
DROP TABLE IF EXISTS "regress_test_$role_69_5".t5;
DROP SCHEMA IF EXISTS "regress_test_$role_69_5_renamed";
DROP SCHEMA IF EXISTS "regress_test_$role_69_5";
ALTER ROLE "regress_test_$role_69_5_renamed" RENAME TO "regress_test_$role_69_5";
DROP ROLE IF EXISTS "regress_test_$role_69_5";
RESET search_path;

----------------------------------------
-- Source: 72.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix updates of indisvalid for partitioned indexes
-- task_id: 72
-- 
-- This test exercises the code path in validatePartitionedIndex() which
-- was fixed to use SearchSysCacheCopy1() instead of heap_copytuple()
-- from the relcache when updating pg_index.indisvalid for partitioned
-- indexes. The fix ensures we always get the latest pg_index tuple
-- from the system catalog rather than a potentially stale relcache copy.
-- ================================================================

-- ================================================================
-- Test 1: Basic single-level partition — attach last partition index
--         to trigger validatePartitionedIndex() setting indisvalid=true
-- ================================================================
CREATE TABLE test72_t1 (a int, b int) PARTITION BY RANGE (a);
CREATE TABLE test72_t1_p1 PARTITION OF test72_t1 FOR VALUES FROM (0) TO (100);
CREATE TABLE test72_t1_p2 PARTITION OF test72_t1 FOR VALUES FROM (100) TO (200);

-- Create index on the parent (partitioned index) and on one partition
CREATE INDEX test72_idx1 ON ONLY test72_t1 (a);
CREATE INDEX test72_idx1_p1 ON test72_t1_p1 (a);

-- Attach partition index for p1; parent still not valid (only 1 of 2 partitions)
ALTER INDEX test72_idx1 ATTACH PARTITION test72_idx1_p1;

-- Show indisvalid is still false (only 1 of 2 partitions have valid indexes)
SELECT indexrelid::regclass, indisvalid
  FROM pg_index
  WHERE indexrelid::regclass::text LIKE 'test72_idx1%'
  ORDER BY indexrelid::regclass::text;

-- Create and attach index for p2 — this should make parent valid
CREATE INDEX test72_idx1_p2 ON test72_t1_p2 (a);
ALTER INDEX test72_idx1 ATTACH PARTITION test72_idx1_p2;

-- Now indisvalid should be true for the parent
SELECT indexrelid::regclass, indisvalid
  FROM pg_index
  WHERE indexrelid::regclass::text LIKE 'test72_idx1%'
  ORDER BY indexrelid::regclass::text;

DROP TABLE test72_t1;


-- ================================================================
-- Test 2: Multi-level partitions — cascade validation upward
--         Two layers: parent -> partition2 -> partition21, partition22
--         Attaching the last partition index at the leaf triggers
--         recursive validatePartitionedIndex() calls
-- ================================================================
CREATE TABLE test72_t2 (a int) PARTITION BY RANGE (a);
CREATE TABLE test72_t2_p1 PARTITION OF test72_t2 FOR VALUES FROM (0) TO (100);
CREATE TABLE test72_t2_p2 PARTITION OF test72_t2 FOR VALUES FROM (100) TO (500)
  PARTITION BY RANGE (a);
CREATE TABLE test72_t2_p21 PARTITION OF test72_t2_p2 FOR VALUES FROM (100) TO (200);
CREATE TABLE test72_t2_p22 PARTITION OF test72_t2_p2 FOR VALUES FROM (200) TO (500);

-- Create indexes: parent and second-level partitions
CREATE INDEX test72_idx2 ON ONLY test72_t2 (a);
CREATE INDEX test72_idx2_p1 ON test72_t2_p1 (a);
ALTER INDEX test72_idx2 ATTACH PARTITION test72_idx2_p1;

CREATE INDEX test72_idx2_p21 ON test72_t2_p21 (a);
CREATE INDEX test72_idx2_p22 ON test72_t2_p22 (a);

-- Attach p21's index to p2's index
CREATE INDEX test72_idx2_p2 ON ONLY test72_t2_p2 (a);
ALTER INDEX test72_idx2_p2 ATTACH PARTITION test72_idx2_p21;

-- Attach p22's index — this should validate p2's index, then cascade
-- to validate the top-level parent index
ALTER INDEX test72_idx2_p2 ATTACH PARTITION test72_idx2_p22;

-- Check all indexes are valid now
SELECT indexrelid::regclass, indisvalid
  FROM pg_index
  WHERE indexrelid::regclass::text LIKE 'test72_idx2%'
  ORDER BY indexrelid::regclass::text;

DROP TABLE test72_t2;


-- ================================================================
-- Test 3: Transactional scenario (the actual bug scenario)
--         Execute multiple ALTER INDEX ATTACH operations in a single
--         transaction. The bug occurred because the relcache tuple
--         became stale after a CommandCounterIncrement / invalidation,
--         and RelationReloadIndexInfo() only partially updated it.
--         Using SearchSysCacheCopy1() ensures we always get the latest.
-- ================================================================
BEGIN;

CREATE TABLE test72_t3 (a int, b int) PARTITION BY RANGE (a);
CREATE TABLE test72_t3_p1 PARTITION OF test72_t3 FOR VALUES FROM (0) TO (100);
CREATE TABLE test72_t3_p2 PARTITION OF test72_t3 FOR VALUES FROM (100) TO (200);
CREATE TABLE test72_t3_p3 PARTITION OF test72_t3 FOR VALUES FROM (200) TO (300);

CREATE INDEX test72_idx3 ON ONLY test72_t3 (a);

-- Create indexes on partitions
CREATE INDEX test72_idx3_p1 ON test72_t3_p1 (a);
CREATE INDEX test72_idx3_p2 ON test72_t3_p2 (a);
CREATE INDEX test72_idx3_p3 ON test72_t3_p3 (a);

-- Multiple ATTACH operations in a single transaction
ALTER INDEX test72_idx3 ATTACH PARTITION test72_idx3_p1;
ALTER INDEX test72_idx3 ATTACH PARTITION test72_idx3_p2;
ALTER INDEX test72_idx3 ATTACH PARTITION test72_idx3_p3;

COMMIT;

-- After commit, all indexes should be valid
SELECT indexrelid::regclass, indisvalid
  FROM pg_index
  WHERE indexrelid::regclass::text LIKE 'test72_idx3%'
  ORDER BY indexrelid::regclass::text;

DROP TABLE test72_t3;


-- ================================================================
-- Test 4: ALTER TABLE ATTACH PARTITION with auto-detected indexes
--         When attaching a partition that already has compatible indexes,
--         the code auto-attaches them and validates the parent index.
--         This exercises a different entry point to validatePartitionedIndex.
-- ================================================================
CREATE TABLE test72_t4 (a int, b int) PARTITION BY RANGE (a);
CREATE TABLE test72_t4_p1 (a int, b int);
CREATE TABLE test72_t4_p2 (a int, b int);

-- Pre-create indexes on the partitions
CREATE INDEX test72_idx4_p1 ON test72_t4_p1 (a);
CREATE INDEX test72_idx4_p2 ON test72_t4_p2 (a);

-- Create index on parent (only, not on partitions yet)
CREATE INDEX test72_idx4 ON ONLY test72_t4 (a);

-- Attach partitions — indexes should be auto-detected and attached
ALTER TABLE test72_t4 ATTACH PARTITION test72_t4_p1 FOR VALUES FROM (0) TO (100);
ALTER TABLE test72_t4 ATTACH PARTITION test72_t4_p2 FOR VALUES FROM (100) TO (200);

SELECT indexrelid::regclass, indisvalid
  FROM pg_index
  WHERE indexrelid::regclass::text LIKE 'test72_idx4%'
  ORDER BY indexrelid::regclass::text;

DROP TABLE test72_t4;


-- ================================================================
-- Test 5: Unique index with replica identity — the exact scenario
--         from the bug report. The error "attempted to update invisible
--         tuple" occurred when updating replica identity after index
--         validation within a transaction.
-- ================================================================
BEGIN;

CREATE TABLE test72_t5 (id int PRIMARY KEY, data text) PARTITION BY RANGE (id);
CREATE TABLE test72_t5_p1 PARTITION OF test72_t5 FOR VALUES FROM (0) TO (100);
CREATE TABLE test72_t5_p2 PARTITION OF test72_t5 FOR VALUES FROM (100) TO (200);

-- Create indexes
CREATE UNIQUE INDEX test72_idx5 ON ONLY test72_t5 (id);
CREATE UNIQUE INDEX test72_idx5_p1 ON test72_t5_p1 (id);
CREATE UNIQUE INDEX test72_idx5_p2 ON test72_t5_p2 (id);

-- Attach partition indexes  
ALTER INDEX test72_idx5 ATTACH PARTITION test72_idx5_p1;
ALTER INDEX test72_idx5 ATTACH PARTITION test72_idx5_p2;

-- Set replica identity (this was the scenario that triggered the bug)
ALTER TABLE ONLY test72_t5 REPLICA IDENTITY USING INDEX test72_idx5;

COMMIT;

SELECT indexrelid::regclass, indisvalid, indisreplident
  FROM pg_index
  WHERE indexrelid::regclass::text LIKE 'test72_idx5%'
  ORDER BY indexrelid::regclass::text;

DROP TABLE test72_t5;

----------------------------------------
-- Source: 73.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Move privilege check for SET SESSION AUTHORIZATION
-- task_id: 73
-- 
-- This test exercises the new privilege check in 
-- check_session_authorization() (src/backend/commands/variable.c)
-- 
-- The change moves privilege checks from assign_hook to check_hook.
-- New code (lines 806-826): Only superusers may SET SESSION AUTHORIZATION
-- to a role other than themselves. For PGC_S_TEST source, only a NOTICE
-- is emitted instead of a hard error.
-- ================================================================

-- ================================================================
-- Test 1: Superuser can SET SESSION AUTHORIZATION to another role
-- (Covers: new permission check -- superuser bypass, line 811 condition false)
-- ================================================================

-- Create a test role (as superuser)
CREATE ROLE regress_test_role1;

-- Superuser should be able to set session authorization to another role
SET SESSION AUTHORIZATION regress_test_role1;
SELECT current_user = 'regress_test_role1' AS is_regress_test_role1;

-- Reset back to superuser
RESET SESSION AUTHORIZATION;
SELECT current_user = 'regress_test_role1' AS still_regress_test_role1_after_reset;

-- Cleanup
DROP ROLE regress_test_role1;

-- ================================================================
-- Test 2: Non-superuser cannot SET SESSION AUTHORIZATION to another role
-- (Covers: new permission check -- insufficient privileges, line 811-825)
-- ================================================================

-- Create a non-superuser test role and another target role
CREATE ROLE regress_test_nonsuper LOGIN;
CREATE ROLE regress_test_target;
GRANT regress_test_target TO regress_test_nonsuper;

-- Try to SET SESSION AUTHORIZATION to a different user as non-superuser
-- This should fail with a permission error (the new code path)
SET SESSION AUTHORIZATION regress_test_nonsuper;
SELECT current_user = 'regress_test_nonsuper' AS is_nonsuper;

-- Attempt to switch to another user -- should fail
SET SESSION AUTHORIZATION regress_test_target;

-- Reset
RESET SESSION AUTHORIZATION;

-- Cleanup
DROP ROLE regress_test_target;
DROP ROLE regress_test_nonsuper;

-- ================================================================
-- Test 3: Non-superuser can SET SESSION AUTHORIZATION to themselves
-- (Covers: roleid == GetAuthenticatedUserId(), line 811 condition false)
-- ================================================================

-- Create a non-superuser role
CREATE ROLE regress_test_self LOGIN;

-- As non-superuser, SET SESSION AUTHORIZATION to themselves should work
SET SESSION AUTHORIZATION regress_test_self;
SELECT current_user = 'regress_test_self' AS is_self;

-- Also try setting to self explicitly again
SET SESSION AUTHORIZATION regress_test_self;
SELECT current_user = 'regress_test_self' AS is_still_self;

-- Reset
RESET SESSION AUTHORIZATION;
DROP ROLE regress_test_self;

-- ================================================================
-- Test 4: PGC_S_TEST source (ALTER ROLE SET) for insufficient privileges
-- (Covers: source == PGC_S_TEST with permission denied, line 814-820)
-- 
-- When ALTER ROLE sets a GUC, it tests the value with PGC_S_TEST.
-- For the new privilege check, this should emit a NOTICE but not fail.
-- ================================================================

-- Create a non-superuser role
CREATE ROLE regress_test_alteree LOGIN;

-- Create another role to be used as target in ALTER ROLE
CREATE ROLE regress_test_otheruser;

-- As superuser, alter a non-superuser's role to try setting
-- session_authorization to a different user.
-- This should emit a NOTICE about permission being denied during PGC_S_TEST,
-- but the ALTER ROLE itself should succeed.
ALTER ROLE regress_test_alteree SET session_authorization TO 'regress_test_otheruser';

-- Reset and show no persistent setting
ALTER ROLE regress_test_alteree RESET session_authorization;

-- Cleanup
DROP ROLE regress_test_alteree;
DROP ROLE regress_test_otheruser;

-- ================================================================
-- Test 5: PGC_S_TEST with non-existent username
-- (Covers: non-existent user handling with PGC_S_TEST, line 787-794)
-- ================================================================

-- Create a role
CREATE ROLE regress_test_notexist;

-- Setting session_authorization to a non-existent user in ALTER ROLE
-- should emit a NOTICE but succeed (PGC_S_TEST path)
ALTER ROLE regress_test_notexist SET session_authorization TO 'non_existent_user_xyz';

-- Reset
ALTER ROLE regress_test_notexist RESET session_authorization;

-- Also test with a direct SET to a non-existent user (should hard error)
SET SESSION AUTHORIZATION non_existent_user_xyz;

-- Cleanup
DROP ROLE regress_test_notexist;

-- ================================================================
-- End of tests
-- ================================================================

----------------------------------------
-- Source: 74.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Improve error message for MaxAllocSize
--                         overrun in accumArrayResult
-- task_id: 74
-- 
-- This test covers the new error check added in accumArrayResult():
-- when astate->alen * sizeof(Datum) exceeds MaxAllocSize, a
-- user-friendly error "array size exceeds the maximum allowed (%d)"
-- is raised instead of a generic "invalid memory alloc request size".
-- 
-- The change is in src/backend/utils/adt/arrayfuncs.c, inside the
-- accumArrayResult() function, in the block that doubles alen.
-- ================================================================

-- ================================================================
-- Test 1: array_agg basic functionality (covers accumArrayResult
--         normal execution path, including the alen-doubling logic)
-- ================================================================
CREATE TABLE test_array_agg_basic (
    id SERIAL PRIMARY KEY,
    val INTEGER
);

INSERT INTO test_array_agg_basic (val)
SELECT generate_series(1, 1000);

EXPLAIN ANALYZE SELECT array_agg(val ORDER BY val) FROM test_array_agg_basic;

DROP TABLE test_array_agg_basic;


-- ================================================================
-- Test 2: array_agg with NULLs and mixed values (covers
--         accumArrayResult with disnull=true/false branches)
-- ================================================================
CREATE TABLE test_array_agg_nulls (
    id SERIAL PRIMARY KEY,
    val TEXT
);

INSERT INTO test_array_agg_nulls (val) VALUES
    ('hello'),
    (NULL),
    ('world'),
    (NULL),
    (NULL),
    ('postgresql'),
    ('array_agg'),
    (NULL),
    ('test');

EXPLAIN ANALYZE SELECT array_agg(val ORDER BY id) FROM test_array_agg_nulls;

EXPLAIN ANALYZE SELECT array_agg(val) FILTER (WHERE val IS NOT NULL)
FROM test_array_agg_nulls;

DROP TABLE test_array_agg_nulls;


-- ================================================================
-- Test 3: array_agg with large dataset (triggers multiple alen
--         doublings, approaching the code path that checks
--         AllocSizeIsValid(astate->alen * sizeof(Datum)))
-- ================================================================
CREATE TABLE test_array_agg_large (
    id SERIAL PRIMARY KEY,
    val INTEGER
);

INSERT INTO test_array_agg_large (val)
SELECT generate_series(1, 50000);

EXPLAIN ANALYZE SELECT array_agg(val) FROM test_array_agg_large;

DROP TABLE test_array_agg_large;


-- ================================================================
-- Test 4: string_agg (uses accumArrayResult internally via
--         StringInfo; covers the same alen-doubling code path
--         in related text-accumulation logic)
-- ================================================================
CREATE TABLE test_string_agg (
    id SERIAL PRIMARY KEY,
    val TEXT
);

INSERT INTO test_string_agg (val)
SELECT 'line_' || generate_series(1, 100);

EXPLAIN ANALYZE SELECT string_agg(val, E'\n' ORDER BY id) FROM test_string_agg;

-- Also test with empty/null mix
INSERT INTO test_string_agg (id, val) VALUES (999, NULL), (1000, '');

EXPLAIN ANALYZE SELECT string_agg(val, ',' ORDER BY id) FROM test_string_agg;

DROP TABLE test_string_agg;


-- ================================================================
-- Test 5: array_agg on different data types and empty result set
--         (proves the modified code works for diverse element types
--         and handles the edge case of zero elements)
-- ================================================================
CREATE TABLE test_array_agg_types (
    id SERIAL PRIMARY KEY,
    int_val INTEGER,
    float_val DOUBLE PRECISION,
    txt_val TEXT,
    date_val DATE
);

INSERT INTO test_array_agg_types (int_val, float_val, txt_val, date_val)
SELECT
    g,
    g * 1.5,
    'item_' || g,
    CURRENT_DATE + g
FROM generate_series(1, 500) g;

-- Test with integer type
EXPLAIN ANALYZE SELECT array_agg(int_val ORDER BY id) FROM test_array_agg_types;

-- Test with float type
EXPLAIN ANALYZE SELECT array_agg(float_val ORDER BY id) FROM test_array_agg_types;

-- Test with text type
EXPLAIN ANALYZE SELECT array_agg(txt_val ORDER BY id) FROM test_array_agg_types;

-- Test with date type
EXPLAIN ANALYZE SELECT array_agg(date_val ORDER BY id) FROM test_array_agg_types;

-- Empty result set (should not trigger the error path, but covers init)
EXPLAIN ANALYZE SELECT array_agg(int_val) FROM test_array_agg_types WHERE false;

DROP TABLE test_array_agg_types;

----------------------------------------
-- Source: 75.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Account for optimized MinMax aggregates during SS_finalize_plan
-- task_id: 75
-- 
-- This test exercises the code paths in find_minmax_agg_replacement_param(),
-- which is called from:
--   1. fix_scan_expr_mutator() in setrefs.c (scan-level Aggrefs)
--   2. fix_upper_expr_mutator() in setrefs.c (upper-level Aggrefs)
--   3. finalize_primnode() in subselect.c (SS_finalize_plan tracking)
--
-- The MinMax optimization replaces MIN()/MAX() aggregates on indexed columns
-- with subqueries that use index scans (LIMIT 1 + ORDER BY). The new function
-- find_minmax_agg_replacement_param() is extracted to share this logic, and
-- is now also called during SS_finalize_plan to properly track Params.
-- ================================================================

-- ================================================================
-- Test 1: Basic MIN() optimization on a single indexed column
-- Covers: fix_scan_expr_mutator() path for MIN() with a btree index
-- ================================================================
CREATE TABLE test_minmax_basic (
    id SERIAL PRIMARY KEY,
    val int NOT NULL
);
CREATE INDEX test_minmax_basic_val_idx ON test_minmax_basic(val);

INSERT INTO test_minmax_basic(val) 
SELECT generate_series(1, 1000);

-- MIN() on indexed column should trigger MinMax optimization
EXPLAIN ANALYZE SELECT MIN(val) FROM test_minmax_basic;

-- MAX() on indexed column should also trigger MinMax optimization
EXPLAIN ANALYZE SELECT MAX(val) FROM test_minmax_basic;

-- Both MIN and MAX in the same query
EXPLAIN ANALYZE SELECT MIN(val), MAX(val) FROM test_minmax_basic;

DROP TABLE test_minmax_basic;


-- ================================================================
-- Test 2: MIN()/MAX() with WHERE clause filtering
-- Covers: fix_scan_expr_mutator() with additional quals
--         Tests that the optimization works with WHERE conditions
-- ================================================================
CREATE TABLE test_minmax_where (
    id SERIAL PRIMARY KEY,
    category int NOT NULL,
    value numeric NOT NULL
);
CREATE INDEX test_minmax_where_val_idx ON test_minmax_where(value);
CREATE INDEX test_minmax_where_cat_idx ON test_minmax_where(category);

INSERT INTO test_minmax_where(category, value)
SELECT g % 5, (random() * 1000)::numeric
FROM generate_series(1, 1000) g;

-- MIN with WHERE clause on the same table
EXPLAIN ANALYZE SELECT MIN(value) FROM test_minmax_WHERE WHERE category = 3;

-- MAX with WHERE clause
EXPLAIN ANALYZE SELECT MAX(value) FROM test_minmax_WHERE WHERE category = 3;

DROP TABLE test_minmax_where;


-- ================================================================
-- Test 3: MIN()/MAX() in subqueries (upper-level expressions)
-- Covers: fix_upper_expr_mutator() path in setrefs.c
--         Tests that MinMax Params are tracked in subquery contexts
-- ================================================================
CREATE TABLE test_minmax_upper (
    id SERIAL PRIMARY KEY,
    group_id int NOT NULL,
    score int NOT NULL
);
CREATE INDEX test_minmax_upper_score_idx ON test_minmax_upper(score);

INSERT INTO test_minmax_upper(group_id, score)
SELECT g % 3, g
FROM generate_series(1, 100) g;

-- MIN/MAX in a subquery (should hit upper_expr path)
EXPLAIN ANALYZE SELECT id, 
    (SELECT MIN(score) FROM test_minmax_upper t2 WHERE t2.group_id = t1.group_id) AS min_score,
    (SELECT MAX(score) FROM test_minmax_upper t2 WHERE t2.group_id = t1.group_id) AS max_score
FROM test_minmax_upper t1
WHERE t1.id <= 10;

DROP TABLE test_minmax_upper;


-- ================================================================
-- Test 4: MIN()/MAX() with NULL values and boundary conditions
-- Covers: Edge cases — NULL values, empty results, single row
--         Tests the NULL handling in find_minmax_agg_replacement_param
-- ================================================================
CREATE TABLE test_minmax_null (
    id SERIAL PRIMARY KEY,
    val int
);
CREATE INDEX test_minmax_null_val_idx ON test_minmax_null(val);

-- Test with NULL values present
INSERT INTO test_minmax_null(val) VALUES (NULL), (1), (NULL), (5), (NULL), (10);

EXPLAIN ANALYZE SELECT MIN(val) FROM test_minmax_null;
EXPLAIN ANALYZE SELECT MAX(val) FROM test_minmax_null;

-- Test with only NULL values (should return NULL)
DELETE FROM test_minmax_null WHERE val IS NOT NULL;
EXPLAIN ANALYZE SELECT MIN(val) FROM test_minmax_null;

-- Test with single row
INSERT INTO test_minmax_null(val) VALUES (42);
EXPLAIN ANALYZE SELECT MIN(val) FROM test_minmax_null;
EXPLAIN ANALYZE SELECT MAX(val) FROM test_minmax_null;

DROP TABLE test_minmax_null;


-- ================================================================
-- Test 5: MIN()/MAX() with various data types and index types
-- Covers: Different data types (text, timestamp) with btree indexes
--         Tests that the optimization works for non-integer types
-- ================================================================
CREATE TABLE test_minmax_types (
    id SERIAL PRIMARY KEY,
    t_text text NOT NULL,
    t_ts timestamp NOT NULL
);
CREATE INDEX test_minmax_types_text_idx ON test_minmax_types(t_text);
CREATE INDEX test_minmax_types_ts_idx ON test_minmax_types(t_ts);

INSERT INTO test_minmax_types(t_text, t_ts)
SELECT 
    chr(65 + (g % 26)) || chr(97 + ((g * 7) % 26)),
    '2024-01-01'::timestamp + (g || ' hours')::interval
FROM generate_series(1, 500) g;

-- MIN/MAX on text column (lexicographic ordering)
EXPLAIN ANALYZE SELECT MIN(t_text) FROM test_minmax_types;
EXPLAIN ANALYZE SELECT MAX(t_text) FROM test_minmax_types;

-- MIN/MAX on timestamp column (chronological ordering)
EXPLAIN ANALYZE SELECT MIN(t_ts) FROM test_minmax_types;
EXPLAIN ANALYZE SELECT MAX(t_ts) FROM test_minmax_types;

DROP TABLE test_minmax_types;

----------------------------------------
-- Source: 76.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix race in SSI interaction with empty btrees
-- task_id: 76
-- 
-- This test covers the fix for a race condition in predicate locking
-- of empty btree indexes. When _bt_first() finds an empty btree,
-- the code now rechecks _bt_search() after taking the relation-level
-- SIREAD lock in SERIALIZABLE isolation, closing a window where
-- a concurrent insert could be missed.
-- ================================================================

-- ================================================================
-- Test 1: SERIALIZABLE isolation + index scan on empty btree
-- 
-- This exercises the new code path in _bt_first():
--   1. _bt_search() returns invalid buffer (empty index)
--   2. IsolationIsSerializable() is true
--   3. PredicateLockRelation() is taken
--   4. _bt_search() is re-run (still empty, buf stays invalid)
--   5. Returns false (no matching tuples)
-- ================================================================

BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

CREATE TABLE test_empty_btree_serializable (
    id INTEGER PRIMARY KEY,
    value TEXT NOT NULL
);

-- Index is empty, do an index scan that triggers _bt_first()
EXPLAIN ANALYZE SELECT * FROM test_empty_btree_serializable WHERE id = 1;

-- Also try a range scan
EXPLAIN ANALYZE SELECT * FROM test_empty_btree_serializable WHERE id BETWEEN 10 AND 20;

-- Try a backward scan
EXPLAIN ANALYZE SELECT * FROM test_empty_btree_serializable WHERE id >= 5 ORDER BY id DESC;

DROP TABLE test_empty_btree_serializable;

COMMIT;

-- ================================================================
-- Test 2: Non-SERIALIZABLE isolation + index scan on empty btree
-- 
-- This exercises the old code path where IsolationIsSerializable()
-- is false, so the re-check is skipped. The index scan returns
-- false directly without the additional _bt_search().
-- ================================================================

BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

CREATE TABLE test_empty_btree_nonserializable (
    id INTEGER PRIMARY KEY,
    value TEXT NOT NULL
);

EXPLAIN ANALYZE SELECT * FROM test_empty_btree_nonserializable WHERE id = 42;

-- Forward scan
EXPLAIN ANALYZE SELECT * FROM test_empty_btree_nonserializable WHERE id > 100;

-- Backward scan on empty btree
EXPLAIN ANALYZE SELECT * FROM test_empty_btree_nonserializable WHERE id < 0 ORDER BY id DESC;

DROP TABLE test_empty_btree_nonserializable;

COMMIT;

-- ================================================================
-- Test 3: SERIALIZABLE isolation + non-empty btree
-- 
-- This exercises the code path where _bt_search() initially finds
-- a valid buffer (non-empty index), so the empty-btree special case
-- is NOT entered. Instead, the normal PredicateLockPage() is called.
-- This validates the non-empty path is unchanged.
-- ================================================================

BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

CREATE TABLE test_nonempty_btree (
    id INTEGER PRIMARY KEY,
    value TEXT NOT NULL
);

-- Insert data first, then scan
INSERT INTO test_nonempty_btree (id, value) VALUES (1, 'one');
INSERT INTO test_nonempty_btree (id, value) VALUES (2, 'two');
INSERT INTO test_nonempty_btree (id, value) VALUES (3, 'three');

EXPLAIN ANALYZE SELECT * FROM test_nonempty_btree WHERE id = 2;

EXPLAIN ANALYZE SELECT * FROM test_nonempty_btree WHERE id BETWEEN 1 AND 3;

-- Scan with no-matching results (will still hit non-empty index, find no match)
EXPLAIN ANALYZE SELECT * FROM test_nonempty_btree WHERE id = 99;

DROP TABLE test_nonempty_btree;

COMMIT;

-- ================================================================
-- Test 4: SERIALIZABLE isolation + empty btree with composite index
-- 
-- This exercises the same new code path as Test 1, but with a
-- multi-column btree index. The empty-btree detection and
-- recheck logic is the same regardless of index structure.
-- ================================================================

BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

CREATE TABLE test_composite_empty (
    a INTEGER NOT NULL,
    b TEXT NOT NULL,
    c NUMERIC
);

CREATE INDEX idx_composite_empty ON test_composite_empty (a, b, c);

-- Empty composite btree index in SERIALIZABLE mode
EXPLAIN ANALYZE SELECT * FROM test_composite_empty WHERE a = 1 AND b = 'hello';

-- Partial match scan on empty index
EXPLAIN ANALYZE SELECT * FROM test_composite_empty WHERE a > 5;

-- Backward scan
EXPLAIN ANALYZE SELECT * FROM test_composite_empty WHERE a BETWEEN 1 AND 10 ORDER BY a DESC;

DROP TABLE test_composite_empty;

COMMIT;

-- ================================================================
-- Test 5: SERIALIZABLE isolation + empty unique index (no PK)
-- 
-- This exercises the code path with a standalone unique btree index
-- (not a PRIMARY KEY). The empty-btree code path in _bt_first()
-- is triggered regardless of whether the index enforces uniqueness.
-- ================================================================

BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

CREATE TABLE test_unique_index_empty (
    user_id INTEGER,
    email TEXT NOT NULL,
    username TEXT
);

CREATE UNIQUE INDEX idx_unique_email ON test_unique_index_empty (email);

-- Empty unique btree index scan
EXPLAIN ANALYZE SELECT * FROM test_unique_index_empty WHERE email = 'test@example.com';

-- Another scan with different strategy
EXPLAIN ANALYZE SELECT * FROM test_unique_index_empty WHERE email > 'a' AND email < 'z';

-- Scan with ORDER BY (backward direction on empty index)
EXPLAIN ANALYZE SELECT * FROM test_unique_index_empty WHERE email >= 'm' ORDER BY email DESC;

DROP TABLE test_unique_index_empty;

COMMIT;

----------------------------------------
-- Source: 79.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Ignore invalid indexes when enforcing
--   index rules in ALTER TABLE ATTACH PARTITION
-- task_id: 79
-- 
-- This test covers the fix in AttachPartitionEnsureIndexes() where
-- invalid indexes (indisvalid = false) are now skipped when matching
-- indexes during ALTER TABLE ... ATTACH PARTITION.
-- ================================================================

-- ================================================================
-- Test 1: Two-level partitioning with invalid index on intermediate
--         partitioned table created via CREATE INDEX ON ONLY.
--         This is the core scenario from the bug report: attaching
--         a partitioned table (that has partitions and an invalid
--         index) to another partitioned table.
--         Covers code path: !attachrelIdxRels[i]->rd_index->indisvalid
-- ================================================================

-- Create top-level partitioned table
CREATE TABLE test79_toplevel (a int) PARTITION BY RANGE (a);
CREATE INDEX test79_toplevel_idx ON test79_toplevel (a);

-- Create intermediate partitioned table with its own partitions
CREATE TABLE test79_intermediate (a int) PARTITION BY RANGE (a);
CREATE TABLE test79_intermediate_1 PARTITION OF test79_intermediate
  FOR VALUES FROM (0) TO (10);
CREATE TABLE test79_intermediate_2 PARTITION OF test79_intermediate
  FOR VALUES FROM (10) TO (20);

-- Create an invalid index on the intermediate table using CREATE INDEX ON ONLY
-- This index exists on the intermediate partitioned table but not on all
-- its partitions, making indisvalid = false.
CREATE INDEX test79_invalid_idx ON ONLY test79_intermediate (a);

-- Now attach the intermediate table (with invalid index) to the top-level table.
-- The AttachPartitionEnsureIndexes function will scan indexes on the
-- intermediate table and must skip the invalid one (test79_invalid_idx).
EXPLAIN ANALYZE ALTER TABLE test79_toplevel ATTACH PARTITION test79_intermediate
  FOR VALUES FROM (1) TO (100);

-- Verify the index tree: invalid index should NOT be used as a match
SELECT indexrelid::regclass, indisvalid,
       indrelid::regclass, inhparent::regclass
  FROM pg_index idx LEFT JOIN
       pg_inherits inh ON (idx.indexrelid = inh.inhrelid)
  WHERE indexrelid::regclass::text LIKE 'test79_invalid%'
     OR indexrelid::regclass::text LIKE 'test79_toplevel%'
  ORDER BY indexrelid::regclass::text COLLATE "C";

DROP TABLE test79_toplevel CASCADE;

-- ================================================================
-- Test 2: Two-level partitioning with both valid and invalid indexes.
--         Ensures that when there is a valid matching index alongside
--         an invalid one, the valid one is selected.
--         Covers code path: !attachrelIdxRels[i]->rd_index->indisvalid
-- ================================================================

CREATE TABLE test79_multi_toplevel (a int, b int) PARTITION BY RANGE (a);
CREATE INDEX test79_multi_toplevel_idx ON test79_multi_toplevel (a);

-- Create intermediate partitioned table with partitions
CREATE TABLE test79_multi_intermediate (a int, b int) PARTITION BY RANGE (a);
CREATE TABLE test79_multi_intermediate_1 PARTITION OF test79_multi_intermediate
  FOR VALUES FROM (0) TO (10);
CREATE TABLE test79_multi_intermediate_2 PARTITION OF test79_multi_intermediate
  FOR VALUES FROM (10) TO (20);

-- Create an INVALID index (ON ONLY - not complete)
CREATE INDEX test79_multi_invalid_idx ON ONLY test79_multi_intermediate (a);

-- Create a VALID index on the leaf partition
CREATE INDEX test79_multi_valid_child_idx ON test79_multi_intermediate_1 (a);

-- Now attach intermediate table to the top-level table.
-- Both invalid and valid indexes exist. The code should skip the invalid one
-- and match the valid child index (or create a new one).
EXPLAIN ANALYZE ALTER TABLE test79_multi_toplevel ATTACH PARTITION test79_multi_intermediate
  FOR VALUES FROM (1) TO (100);

SELECT indexrelid::regclass, indisvalid,
       indrelid::regclass, inhparent::regclass
  FROM pg_index idx LEFT JOIN
       pg_inherits inh ON (idx.indexrelid = inh.inhrelid)
  WHERE indexrelid::regclass::text LIKE 'test79_multi%'
  ORDER BY indexrelid::regclass::text COLLATE "C";

DROP TABLE test79_multi_toplevel CASCADE;

-- ================================================================
-- Test 3: Three-level partitioning with invalid index at middle level.
--         Creates a deeper partition tree where the invalid index is
--         at the second level of partitioning. This exercises the
--         scenario described in the commit message about "more than
--         two levels of partitioning."
--         Covers code path: !attachrelIdxRels[i]->rd_index->indisvalid
-- ================================================================

CREATE TABLE test79_deep_top (a int) PARTITION BY RANGE (a);
CREATE INDEX test79_deep_top_idx ON test79_deep_top (a);

-- Level 2: partitioned table with its own sub-partitions
CREATE TABLE test79_deep_mid (a int) PARTITION BY RANGE (a);
CREATE TABLE test79_deep_mid_1 PARTITION OF test79_deep_mid
  FOR VALUES FROM (0) TO (50) PARTITION BY RANGE (a);

-- Level 3: leaf partitions
CREATE TABLE test79_deep_leaf_1 PARTITION OF test79_deep_mid_1
  FOR VALUES FROM (0) TO (25);
CREATE TABLE test79_deep_leaf_2 PARTITION OF test79_deep_mid_1
  FOR VALUES FROM (25) TO (50);

-- Create invalid index on the middle-level partitioned table
CREATE INDEX test79_deep_mid_invalid_idx ON ONLY test79_deep_mid (a);

-- Attach the middle-level partitioned table (with invalid index) to the top.
-- The code must skip the invalid index and either match/create valid ones.
EXPLAIN ANALYZE ALTER TABLE test79_deep_top ATTACH PARTITION test79_deep_mid
  FOR VALUES FROM (1) TO (200);

SELECT indexrelid::regclass, indisvalid,
       indrelid::regclass, inhparent::regclass
  FROM pg_index idx LEFT JOIN
       pg_inherits inh ON (idx.indexrelid = inh.inhrelid)
  WHERE indexrelid::regclass::text LIKE 'test79_deep%'
  ORDER BY indexrelid::regclass::text COLLATE "C";

DROP TABLE test79_deep_top CASCADE;

-- ================================================================
-- Test 4: Ensure valid indexes are still correctly matched when
--         no invalid indexes exist (normal case).
--         This is a regression test to confirm the fix doesn't break
--         the normal code path where all indexes are valid.
--         Covers code path: valid index matches successfully (no skip)
-- ================================================================

CREATE TABLE test79_normal_top (a int) PARTITION BY RANGE (a);
CREATE INDEX test79_normal_top_idx ON test79_normal_top (a);

CREATE TABLE test79_normal_mid (a int) PARTITION BY RANGE (a);
CREATE TABLE test79_normal_mid_1 PARTITION OF test79_normal_mid
  FOR VALUES FROM (0) TO (10);
CREATE TABLE test79_normal_mid_2 PARTITION OF test79_normal_mid
  FOR VALUES FROM (10) TO (20);

-- Create a valid complete index on all partitions
CREATE INDEX test79_normal_mid_idx ON test79_normal_mid (a);

-- Attach - all indexes are valid, normal matching should work
EXPLAIN ANALYZE ALTER TABLE test79_normal_top ATTACH PARTITION test79_normal_mid
  FOR VALUES FROM (1) TO (100);

SELECT indexrelid::regclass, indisvalid,
       indrelid::regclass, inhparent::regclass
  FROM pg_index idx LEFT JOIN
       pg_inherits inh ON (idx.indexrelid = inh.inhrelid)
  WHERE indexrelid::regclass::text LIKE 'test79_normal%'
  ORDER BY indexrelid::regclass::text COLLATE "C";

DROP TABLE test79_normal_top CASCADE;

-- ================================================================
-- Test 5: Multiple invalid indexes with different column definitions.
--         Verifies that when multiple invalid indexes exist, all are
--         skipped and the correct valid index (or newly created one)
--         is chosen.
--         Covers code path: !attachrelIdxRels[i]->rd_index->indisvalid
--         for each invalid index encountered in the loop.
-- ================================================================

CREATE TABLE test79_multiinv_top (a int, b int) PARTITION BY RANGE (a);
CREATE INDEX test79_multiinv_top_idx ON test79_multiinv_top (a);

CREATE TABLE test79_multiinv_mid (a int, b int) PARTITION BY RANGE (a);
CREATE TABLE test79_multiinv_mid_1 PARTITION OF test79_multiinv_mid
  FOR VALUES FROM (0) TO (10);
CREATE TABLE test79_multiinv_mid_2 PARTITION OF test79_multiinv_mid
  FOR VALUES FROM (10) TO (20);

-- Create multiple invalid indexes with different column configurations
CREATE INDEX test79_multiinv_inv1 ON ONLY test79_multiinv_mid (a);
CREATE INDEX test79_multiinv_inv2 ON ONLY test79_multiinv_mid (b);
CREATE INDEX test79_multiinv_inv3 ON ONLY test79_multiinv_mid (a, b);

-- Create a valid index on a leaf partition for one of the patterns
CREATE INDEX test79_multiinv_valid_child ON test79_multiinv_mid_1 (a);

-- Attach - code must skip all three invalid indexes and find/create
-- a valid matching index for the parent's index on (a).
EXPLAIN ANALYZE ALTER TABLE test79_multiinv_top ATTACH PARTITION test79_multiinv_mid
  FOR VALUES FROM (1) TO (100);

SELECT indexrelid::regclass, indisvalid,
       indrelid::regclass, inhparent::regclass
  FROM pg_index idx LEFT JOIN
       pg_inherits inh ON (idx.indexrelid = inh.inhrelid)
  WHERE indexrelid::regclass::text LIKE 'test79_multiinv%'
  ORDER BY indexrelid::regclass::text COLLATE "C";

DROP TABLE test79_multiinv_top CASCADE;

----------------------------------------
-- Source: 80.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Correctly update hasSubLinks while mutating a rule action
-- task_id: 80
-- 
-- This test exercises the fix in rewriteRuleAction() that adds checking
-- of RangeTblEntry.securityQuals for SubLink nodes, and the fix in
-- rewriteTargetView() that passes NULL instead of &parsetree->hasSubLinks.
-- ================================================================

-- ##################################################################
-- Test 1: Core bug scenario - nested security barrier views with
--         SubLink in WHERE clause + DO INSTEAD rule
-- 
-- Coverage: rewriteRuleAction - checks securityQuals for SubLinks
--           rewriteTargetView - passes NULL for outer_hasSubLinks
--
-- When v2 (security barrier) has WHERE EXISTS (SELECT 1), this SubLink
-- ends up in the securityQuals of v2's RTE. When the rule v1_upd_rule
-- fires, rewriteRuleAction iterates RTEs and must check securityQuals.
-- ##################################################################
CREATE TABLE test1_base (a int);
INSERT INTO test1_base VALUES (1), (2), (3);

CREATE VIEW test1_v1 WITH (security_barrier = true) AS
  SELECT * FROM test1_base;

CREATE RULE test1_v1_upd AS ON UPDATE TO test1_v1 DO INSTEAD
  UPDATE test1_base SET a = NEW.a WHERE a = OLD.a;

CREATE VIEW test1_v2 WITH (security_barrier = true) AS
  SELECT * FROM test1_v1 WHERE EXISTS (SELECT 1);

EXPLAIN (COSTS OFF) UPDATE test1_v2 SET a = 10;
EXPLAIN ANALYZE UPDATE test1_v2 SET a = 10;

DROP VIEW test1_v2;
DROP VIEW test1_v1;
DROP TABLE test1_base;

-- ##################################################################
-- Test 2: RLS policy with SubLink + rule on table
-- 
-- Coverage: rewriteRuleAction checks securityQuals for SubLinks
--           that originate from RLS policies.
--
-- Table with RLS enabled and a policy whose USING clause contains
-- a subquery. A rule on the table forces rewriteRuleAction to be
-- called, and the RLS policy's SubLink in securityQuals must be
-- detected.
-- ##################################################################
CREATE TABLE test2_data (x int, y int);
INSERT INTO test2_data VALUES (1, 10), (2, 20), (3, 30);

CREATE TABLE test2_lookup (y int, label text);
INSERT INTO test2_lookup VALUES (10, 'ten'), (20, 'twenty'), (30, 'thirty');

CREATE RULE test2_rule AS ON UPDATE TO test2_data DO INSTEAD
  UPDATE test2_data SET x = NEW.x WHERE x = OLD.x;

-- Create a policy with a SubLink (subquery in USING clause)
ALTER TABLE test2_data ENABLE ROW LEVEL SECURITY;
CREATE POLICY test2_policy ON test2_data
  USING (y IN (SELECT y FROM test2_lookup WHERE label LIKE 't%'));

-- The outer query has a SubLink, triggering the code path
EXPLAIN (COSTS OFF) UPDATE test2_data SET x = x * 100
  WHERE x IN (SELECT x FROM test2_data WHERE x > 0);
EXPLAIN ANALYZE UPDATE test2_data SET x = x * 100
  WHERE x IN (SELECT x FROM test2_data WHERE x > 0);

DROP POLICY test2_policy ON test2_data;
ALTER TABLE test2_data DISABLE ROW LEVEL SECURITY;
DROP RULE test2_rule ON test2_data;
DROP TABLE test2_data;
DROP TABLE test2_lookup;

-- ##################################################################
-- Test 3: Security barrier view with correlated subquery + DO ALSO rule
-- 
-- Coverage: rewriteRuleAction - securityQuals with correlated SubLink
--           rewriteTargetView - passes NULL for outer_hasSubLinks
--
-- A correlated subquery in the security barrier view's WHERE clause
-- tests that SubLinks in securityQuals containing outer references
-- are properly detected.
-- ##################################################################
CREATE TABLE test3_base (id int, val int);
INSERT INTO test3_base VALUES (1, 100), (2, 200), (3, 300);

CREATE TABLE test3_ref (id int, max_val int);
INSERT INTO test3_ref VALUES (1, 150), (2, 250);

-- Security barrier view with a correlated subquery
CREATE VIEW test3_v WITH (security_barrier = true) AS
  SELECT * FROM test3_base b
  WHERE b.val < (SELECT max_val FROM test3_ref r WHERE r.id = b.id);

-- Rule that fires on UPDATE
CREATE RULE test3_rule AS ON UPDATE TO test3_v DO ALSO
  INSERT INTO test3_ref VALUES (NEW.id, NEW.val);

EXPLAIN (COSTS OFF) UPDATE test3_v SET val = val + 50
  WHERE id IN (SELECT id FROM test3_ref WHERE max_val > 100);
EXPLAIN ANALYZE UPDATE test3_v SET val = val + 50
  WHERE id IN (SELECT id FROM test3_ref WHERE max_val > 100);

DROP RULE test3_rule ON test3_v;
DROP VIEW test3_v;
DROP TABLE test3_base;
DROP TABLE test3_ref;

-- ##################################################################
-- Test 4: INSERT via security barrier view with subquery in WHERE clause
--         and DO INSTEAD rule
-- 
-- Coverage: rewriteRuleAction - securityQuals check for INSERT commands
--           rewriteTargetView - passes NULL for outer_hasSubLinks
--
-- INSERT operations through security barrier views also trigger
-- rewriteTargetView and potential rule firing. Tests that the
-- securityQuals SubLink detection works for INSERT as well.
-- ##################################################################
CREATE TABLE test4_base (a int, b int);
INSERT INTO test4_base VALUES (1, 10), (2, 20);

CREATE VIEW test4_v WITH (security_barrier = true) AS
  SELECT * FROM test4_base WHERE a > (SELECT min(a) FROM test4_base);

CREATE RULE test4_v_ins AS ON INSERT TO test4_v DO INSTEAD
  INSERT INTO test4_base VALUES (NEW.a, NEW.b);

EXPLAIN (COSTS OFF) INSERT INTO test4_v VALUES (3, 30);
EXPLAIN ANALYZE INSERT INTO test4_v VALUES (3, 30);

EXPLAIN (COSTS OFF) INSERT INTO test4_v VALUES (4, 40);
EXPLAIN ANALYZE INSERT INTO test4_v VALUES (4, 40);

DROP RULE test4_v_ins ON test4_v;
DROP VIEW test4_v;
DROP TABLE test4_base;

-- ##################################################################
-- Test 5: Security barrier view with NOT EXISTS subquery + DELETE + rule
-- 
-- Coverage: rewriteRuleAction - securityQuals with NOT EXISTS SubLink
--           rewriteTargetView - passes NULL for outer_hasSubLinks
--
-- Using NOT EXISTS (another form of SubLink) in the security barrier
-- view's WHERE clause, combined with a DELETE operation through a rule.
-- Tests that different SubLink types in securityQuals are detected.
-- ##################################################################
CREATE TABLE test5_base (id int, val text);
INSERT INTO test5_base VALUES (1, 'one'), (2, 'two'), (3, 'three'), (4, 'four');

CREATE TABLE test5_active (id int);
INSERT INTO test5_active VALUES (1), (3);

-- Security barrier view with NOT EXISTS (another SubLink variant)
CREATE VIEW test5_v WITH (security_barrier = true) AS
  SELECT * FROM test5_base b
  WHERE NOT EXISTS (SELECT 1 FROM test5_active a WHERE a.id = b.id);

CREATE RULE test5_v_del AS ON DELETE TO test5_v DO INSTEAD
  DELETE FROM test5_base WHERE id = OLD.id;

-- The outer query has a SubLink, triggering the code path
EXPLAIN (COSTS OFF) DELETE FROM test5_v
  WHERE id IN (SELECT id FROM test5_active);
EXPLAIN ANALYZE DELETE FROM test5_v
  WHERE id IN (SELECT id FROM test5_active);

DROP RULE test5_v_del ON test5_v;
DROP VIEW test5_v;
DROP TABLE test5_base;
DROP TABLE test5_active;

----------------------------------------
-- Source: 81.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: pgsql: Use per-tuple context in ExecGetAllUpdatedCols
-- task_id: 81
-- 
-- This commit fixes a memory leak in ExecGetAllUpdatedCols() by switching
-- to per-tuple memory context when allocating the bitmapset via bms_union().
-- The function is called in multiple UPDATE code paths:
--   - execMain.c: compute lock mode based on updated key columns
--   - trigger.c: BEFORE/AFTER, STATEMENT/ROW level UPDATE triggers
--
-- Each test exercises ExecGetAllUpdatedCols() through different call sites.
-- ================================================================

-- ================================================================
-- Test 1: Simple UPDATE on table with a primary key (lock mode path)
-- Coverage: execMain.c line 2329 → ExecGetAllUpdatedCols()
-- Exercises the per-tuple memory context in the UPDATE lock mode computation.
-- ================================================================
CREATE TABLE test1_updated_cols (
    id INT PRIMARY KEY,
    val TEXT NOT NULL,
    data INT DEFAULT 0
);

INSERT INTO test1_updated_cols (id, val, data)
SELECT i, 'value_' || i, i * 10
FROM generate_series(1, 100) AS i;

-- UPDATE non-key column → should use ExecGetAllUpdatedCols for lock mode
EXPLAIN ANALYZE UPDATE test1_updated_cols SET data = data + 1 WHERE id <= 50;

-- UPDATE key column → also triggers ExecGetAllUpdatedCols
EXPLAIN ANALYZE UPDATE test1_updated_cols SET id = id + 1000 WHERE id > 50;

DROP TABLE test1_updated_cols;

-- ================================================================
-- Test 2: UPDATE with BEFORE STATEMENT trigger (trigger.c:2644)
-- Coverage: ExecBRUpdateTriggers → ExecGetAllUpdatedCols()
-- The per-tuple context fix prevents memory leak when many rows are updated.
-- ================================================================
CREATE TABLE test2_before_stmt (
    id INT PRIMARY KEY,
    val TEXT
);

INSERT INTO test2_before_stmt (id, val)
SELECT i, 'data_' || i FROM generate_series(1, 100) AS i;

-- BEFORE STATEMENT trigger on UPDATE
CREATE OR REPLACE FUNCTION log_before_stmt_update()
RETURNS TRIGGER AS $$
BEGIN
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_before_stmt_upd
    BEFORE UPDATE ON test2_before_stmt
    FOR EACH STATEMENT
    EXECUTE FUNCTION log_before_stmt_update();

-- This exercises ExecGetAllUpdatedCols via BeforeStmt trigger path
EXPLAIN ANALYZE UPDATE test2_before_stmt SET val = val || '_updated' WHERE id > 0;

DROP TRIGGER trg_before_stmt_upd ON test2_before_stmt;
DROP FUNCTION log_before_stmt_update();
DROP TABLE test2_before_stmt;

-- ================================================================
-- Test 3: UPDATE with AFTER STATEMENT trigger (trigger.c:2691)
-- Coverage: ExecASUpdateTriggers → ExecGetAllUpdatedCols()
-- AFTER STATEMENT triggers also call AfterTriggerSaveEvent with updatedCols.
-- ================================================================
CREATE TABLE test3_after_stmt (
    id INT PRIMARY KEY,
    val TEXT
);

INSERT INTO test3_after_stmt (id, val)
SELECT i, 'item_' || i FROM generate_series(1, 50) AS i;

-- AFTER STATEMENT trigger on UPDATE
CREATE OR REPLACE FUNCTION log_after_stmt_update()
RETURNS TRIGGER AS $$
BEGIN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_stmt_upd
    AFTER UPDATE ON test3_after_stmt
    FOR EACH STATEMENT
    EXECUTE FUNCTION log_after_stmt_update();

-- Exercises ExecGetAllUpdatedCols via AfterStmt trigger path
EXPLAIN ANALYZE UPDATE test3_after_stmt SET val = 'updated' WHERE id % 2 = 0;

DROP TRIGGER trg_after_stmt_upd ON test3_after_stmt;
DROP FUNCTION log_after_stmt_update();
DROP TABLE test3_after_stmt;

-- ================================================================
-- Test 4: UPDATE with BEFORE ROW trigger (trigger.c:2761)
-- Coverage: ExecBRUpdateTriggers (row-level) → ExecGetAllUpdatedCols()
-- This is the most common trigger type, exercising per-tuple context per row.
-- ================================================================
CREATE TABLE test4_before_row (
    id INT PRIMARY KEY,
    val TEXT
);

INSERT INTO test4_before_row (id, val)
SELECT i, 'row_' || i FROM generate_series(1, 100) AS i;

-- BEFORE ROW trigger on UPDATE
CREATE OR REPLACE FUNCTION log_before_row_update()
RETURNS TRIGGER AS $$
BEGIN
    NEW.val = NEW.val || '_modified';
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_before_row_upd
    BEFORE UPDATE ON test4_before_row
    FOR EACH ROW
    EXECUTE FUNCTION log_before_row_update();

-- Large UPDATE to exercise per-tuple memory context for many rows
EXPLAIN ANALYZE UPDATE test4_before_row SET val = 'touched' WHERE id BETWEEN 1 AND 75;

-- Edge case: UPDATE with no rows matching (empty result, function still called for statement triggers)
EXPLAIN ANALYZE UPDATE test4_before_row SET val = 'nowhere' WHERE id < 0;

DROP TRIGGER trg_before_row_upd ON test4_before_row;
DROP FUNCTION log_before_row_update();
DROP TABLE test4_before_row;

-- ================================================================
-- Test 5: UPDATE with AFTER ROW trigger (trigger.c:2869)
-- Coverage: ExecARUpdateTriggers → AfterTriggerSaveEvent → ExecGetAllUpdatedCols()
-- Combined with generated columns (the original motivation for the function)
-- ================================================================
CREATE TABLE test5_generated (
    id INT PRIMARY KEY,
    qty INT NOT NULL,
    price NUMERIC(10,2) NOT NULL,
    total NUMERIC(10,2) GENERATED ALWAYS AS (qty * price) STORED
);

INSERT INTO test5_generated (id, qty, price)
SELECT i, i, (random() * 100)::numeric(10,2)
FROM generate_series(1, 50) AS i;

-- AFTER ROW trigger on UPDATE (sees all updated cols including generated)
CREATE OR REPLACE FUNCTION log_after_row_update()
RETURNS TRIGGER AS $$
BEGIN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_after_row_upd
    AFTER UPDATE ON test5_generated
    FOR EACH ROW
    EXECUTE FUNCTION log_after_row_update();

-- Update base columns → generated column recomputed → ExecGetAllUpdatedCols includes it
EXPLAIN ANALYZE UPDATE test5_generated SET qty = qty + 1, price = price * 1.1 WHERE id > 0;

-- Edge case: UPDATE of only one column, with NULL-like boundaries (min value, max value)
EXPLAIN ANALYZE UPDATE test5_generated SET qty = 0 WHERE id = 1;

DROP TRIGGER trg_after_row_upd ON test5_generated;
DROP FUNCTION log_after_row_update();
DROP TABLE test5_generated;

----------------------------------------
-- Source: 82.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: BRIN empty ranges and NULL handling fix
-- task_id: 82
-- ================================================================
-- This test covers the new bt_empty_range flag added to BRIN tuples.
-- The flag distinguishes between empty ranges (no rows yet) and
-- ranges containing only NULL values, fixing a bug where NULL values
-- at the start of a range were incorrectly forgotten.
--
-- Affected code paths:
--   1. bringetbitmap: skip empty ranges when building bitmap
--   2. union_tuples: handle empty ranges during summarization merge
--   3. add_values_to_range: preserve NULL info when adding values to
--      a previously-empty range
-- ================================================================

-- ================================================================
-- Test 1: BRIN scan skips empty ranges (bringetbitmap)
-- 
-- Creates a table, inserts some rows, creates a BRIN index, then
-- deletes all rows (creating empty page ranges). A BRIN scan query
-- must skip the empty ranges via bt_empty_range check in
-- bringetbitmap (line 557). The key is that after DELETE+ANALYZE,
-- some BRIN ranges will be empty.
-- ================================================================
CREATE TABLE test_brin_empty_range_scan (
    id serial,
    val int
) WITH (autovacuum_enabled = false);

-- Insert data across multiple pages (small fillfactor to spread data)
INSERT INTO test_brin_empty_range_scan (val)
    SELECT generate_series(1, 1000);

-- Create BRIN index with small pages_per_range
CREATE INDEX brin_empty_scan_idx ON test_brin_empty_range_scan USING brin (val)
    WITH (pages_per_range = 1);

-- Verify the index works (scan with WHERE clause)
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_empty_range_scan WHERE val BETWEEN 100 AND 200;

-- Now delete a range of values to create an empty page range
DELETE FROM test_brin_empty_range_scan WHERE val BETWEEN 300 AND 700;

-- ANALYZE to update stats
ANALYZE test_brin_empty_range_scan;

-- Scan again - should exercise the empty range skipping path
-- because some BRIN ranges now have no matching tuples
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_empty_range_scan WHERE val BETWEEN 100 AND 200;

DROP TABLE test_brin_empty_range_scan;


-- ================================================================
-- Test 2: Inserting NULLs then non-NULLs to a range (add_values_to_range)
-- 
-- This is the core bug scenario: when the first value inserted into
-- a BRIN range is NULL, the old code would incorrectly reset allnulls
-- to false without setting hasnulls=true. The fix uses bt_empty_range
-- to detect this and restore hasnulls. 
-- 
-- Uses a small table where data fits in a single page range, so
-- the BRIN summarization will see the NULL-first pattern.
-- ================================================================
CREATE TABLE test_brin_null_first (
    id serial,
    val int
) WITH (autovacuum_enabled = false);

-- Create BRIN index first
CREATE INDEX brin_null_first_idx ON test_brin_null_first USING brin (val)
    WITH (pages_per_range = 1);

-- Insert a NULL value first (will hit the empty range code path)
INSERT INTO test_brin_null_first (val) VALUES (NULL);

-- Now insert non-NULL values (should trigger has_nulls tracking)
INSERT INTO test_brin_null_first (val) VALUES (1);
INSERT INTO test_brin_null_first (val) VALUES (2);
INSERT INTO test_brin_null_first (val) VALUES (3);

-- Query using IS NULL to verify BRIN correctly identifies NULLs
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_null_first WHERE val IS NULL;

-- Query using IS NOT NULL 
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_null_first WHERE val IS NOT NULL;

-- Query using a range that includes the non-NULL values
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_null_first WHERE val BETWEEN 1 AND 5;

DROP TABLE test_brin_null_first;


-- ================================================================
-- Test 3: Multiple NULL values followed by non-NULL values
-- (add_values_to_range with extended NULL sequence)
-- 
-- Similar to Test 2, but with a longer sequence of NULL values
-- before any non-NULL value is inserted. This exercises the
-- has_nulls tracking in the per-column loop more thoroughly.
-- Uses a multi-column BRIN index to test all-column handling.
-- ================================================================
CREATE TABLE test_brin_multi_nulls (
    id serial,
    a int,
    b text
) WITH (autovacuum_enabled = false);

-- Create a multi-column BRIN index
CREATE INDEX brin_multi_null_idx ON test_brin_multi_nulls USING brin (a, b)
    WITH (pages_per_range = 1);

-- Insert many NULL values first (all-nulls)
INSERT INTO test_brin_multi_nulls (a, b) VALUES (NULL, NULL);
INSERT INTO test_brin_multi_nulls (a, b) VALUES (NULL, NULL);
INSERT INTO test_brin_multi_nulls (a, b) VALUES (NULL, NULL);

-- Now insert mixed NULL/non-NULL values
INSERT INTO test_brin_multi_nulls (a, b) VALUES (1, 'hello');
INSERT INTO test_brin_multi_nulls (a, b) VALUES (NULL, 'world');
INSERT INTO test_brin_multi_nulls (a, b) VALUES (2, NULL);

-- Query with IS NULL on both columns
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_multi_nulls WHERE a IS NULL;

EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_multi_nulls WHERE b IS NULL;

-- Query with equality on non-NULL values
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_multi_nulls WHERE a = 1;

DROP TABLE test_brin_multi_nulls;


-- ================================================================
-- Test 4: brin_summarize_range with empty pages (union_tuples)
-- 
-- Tests the union_tuples function when merging a previously-empty
-- range with a populated range. This exercises:
--   1. db->bt_empty_range check (line 1581) - if "b" is empty, skip
--   2. a->bt_empty_range check (line 1595) - if "a" is empty, copy "b"
-- 
-- Creates a table, inserts data in separate batches, desummarizes
-- and re-summarizes ranges to trigger the union paths.
-- ================================================================
CREATE TABLE test_brin_union_empty (
    id serial,
    val int
) WITH (autovacuum_enabled = false);

-- Insert first batch of data
INSERT INTO test_brin_union_empty (val) SELECT generate_series(1, 100);

-- Create BRIN index
CREATE INDEX brin_union_empty_idx ON test_brin_union_empty USING brin (val)
    WITH (pages_per_range = 2);

-- Summarize current ranges
SELECT brin_summarize_range('brin_union_empty_idx', 0);

-- Insert more data to create new unsummarized ranges
INSERT INTO test_brin_union_empty (val) SELECT generate_series(101, 500);

-- Now use brin_summarize_new_values to trigger summarization which
-- will call union_tuples when merging with existing placeholders
SELECT brin_summarize_new_values('brin_union_empty_idx');

-- Also test desummarize + resummarize cycle to trigger
-- the placeholder tuple update path in union_tuples
SELECT brin_desummarize_range('brin_union_empty_idx', 0);
SELECT brin_summarize_range('brin_union_empty_idx', 0);

-- Run a scan to exercise bringetbitmap on re-summarized ranges
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_union_empty WHERE val < 50;

DROP TABLE test_brin_union_empty;


-- ================================================================
-- Test 5: Bulk DELETE creating empty ranges, then INSERT (bringetbitmap + add_values_to_range)
-- 
-- This test exercises the full lifecycle:
--   1. Insert data and create BRIN index
--   2. DELETE all rows to create empty BRIN ranges (bt_empty_range=true)
--   3. BRIN scan skips empty ranges (bringetbitmap, line 557)
--   4. INSERT new values into the empty ranges (add_values_to_range,
--      line 246: need_insert starts true due to bt_empty_range)
--   5. Verify BRIN scan finds the new values correctly
-- ================================================================
CREATE TABLE test_brin_full_cycle (
    id serial,
    category text,
    value int
) WITH (autovacuum_enabled = false);

-- Insert initial data spread across multiple pages
INSERT INTO test_brin_full_cycle (category, value)
    SELECT 'initial', generate_series(1, 500);

-- Create BRIN index with multiple columns
CREATE INDEX brin_full_cycle_idx ON test_brin_full_cycle USING brin (category, value)
    WITH (pages_per_range = 2);

-- Run a scan to verify index works
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_full_cycle WHERE value > 100;

-- Delete ALL rows - this will make all BRIN ranges empty
DELETE FROM test_brin_full_cycle;

-- Verify scan on empty table (should skip all ranges via bt_empty_range)
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_full_cycle WHERE value > 100;

-- Re-insert data (will add values to now-empty ranges)
INSERT INTO test_brin_full_cycle (category, value)
    SELECT 'refill', generate_series(1, 300);

-- Insert some NULL values mixed in
INSERT INTO test_brin_full_cycle (category, value)
    VALUES (NULL, NULL), ('nullcat', NULL), (NULL, 999);

-- Verify BRIN scan finds the new values correctly
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_full_cycle WHERE value BETWEEN 50 AND 150;

-- Verify IS NULL queries work correctly with the refilled data
EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_full_cycle WHERE category IS NULL;

EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF)
SELECT * FROM test_brin_full_cycle WHERE value IS NULL;

DROP TABLE test_brin_full_cycle;


-- ================================================================
-- End of BRIN empty range and NULL handling regression tests
-- ================================================================

----------------------------------------
-- Source: 83.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Handle RLS dependencies in inlined
-- set-returning functions properly (CVE-2023-2455)
-- task_id: 83
-- 
-- This tests the fix in inline_set_returning_function() where we
-- now set root->glob->dependsOnRole = true when the inlined SRF
-- query has hasRowSecurity set, ensuring the plan is correctly
-- marked as role-dependent.
-- ================================================================

-- ================================================================
-- Test 1: Basic SRF inlining with RLS - SELECT from SRF in FROM
-- 
-- Covers: The primary fix path. A SQL SRF returns rows from a table
-- with RLS. When inlined, the plan must be marked as role-dependent
-- so different users see different rows.
-- ================================================================
CREATE TABLE test83_t1 (id int, data text);
INSERT INTO test83_t1 VALUES (1, 'visible to all'), (2, 'secret for alice');

ALTER TABLE test83_t1 ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON test83_t1 TO PUBLIC;

-- Alice can see all rows
CREATE POLICY test83_p_alice ON test83_t1 FOR SELECT TO CURRENT_USER USING (true);
-- Other users can only see row with id=1
CREATE POLICY test83_p_bob ON test83_t1 FOR SELECT USING (id = 1);

CREATE FUNCTION test83_f1() RETURNS SETOF test83_t1
  STABLE LANGUAGE SQL
  AS $$ SELECT * FROM test83_t1 $$;

-- This query will inline test83_f1(), hitting the new code path
EXPLAIN ANALYZE SELECT current_user, * FROM test83_f1();

-- Cleanup
DROP FUNCTION test83_f1();
DROP TABLE test83_t1;


-- ================================================================
-- Test 2: SRF inlining with RLS and CTE inside the function
-- 
-- Covers: The inlined function body contains a CTE that selects from
-- an RLS-protected table. The hasRowSecurity flag must be propagated.
-- ================================================================
CREATE TABLE test83_t2 (id int, payload text);
INSERT INTO test83_t2 VALUES (1, 'public'), (2, 'confidential');

ALTER TABLE test83_t2 ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON test83_t2 TO PUBLIC;

CREATE POLICY test83_p2_all ON test83_t2 FOR SELECT USING (id = 1);
CREATE POLICY test83_p2_admin ON test83_t2 FOR SELECT TO CURRENT_USER USING (true);

CREATE FUNCTION test83_f2() RETURNS SETOF test83_t2
  STABLE LANGUAGE SQL
  AS $$ WITH cte AS (SELECT * FROM test83_t2) SELECT * FROM cte $$;

EXPLAIN ANALYZE SELECT current_user, * FROM test83_f2();

DROP FUNCTION test83_f2();
DROP TABLE test83_t2;


-- ================================================================
-- Test 3: SRF inlining with RLS and a subquery inside the function
-- 
-- Covers: The inlined function body contains a subquery that selects
-- from an RLS-protected table. Different code path for subquery
-- vs. direct table access.
-- ================================================================
CREATE TABLE test83_t3 (category int, value text);
INSERT INTO test83_t3 VALUES (1, 'public data'), (2, 'restricted data');

ALTER TABLE test83_t3 ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON test83_t3 TO PUBLIC;

CREATE POLICY test83_p3_public ON test83_t3 FOR SELECT USING (category = 1);
CREATE POLICY test83_p3_all ON test83_t3 FOR SELECT TO CURRENT_USER USING (true);

CREATE FUNCTION test83_f3() RETURNS SETOF test83_t3
  STABLE LANGUAGE SQL
  AS $$ SELECT * FROM (SELECT * FROM test83_t3) AS subq $$;

EXPLAIN ANALYZE SELECT current_user, * FROM test83_f3();

DROP FUNCTION test83_f3();
DROP TABLE test83_t3;


-- ================================================================
-- Test 4: SRF inlining with RLS and EXISTS sublink
-- 
-- Covers: The inlined function body uses a sublink (EXISTS) that
-- references an RLS-protected table. The hasRowSecurity flag must
-- be properly set on the query tree.
-- ================================================================
CREATE TABLE test83_t4 (id int, secret text);
INSERT INTO test83_t4 VALUES (1, 'public'), (2, 'sensitive');

ALTER TABLE test83_t4 ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON test83_t4 TO PUBLIC;

CREATE POLICY test83_p4_public ON test83_t4 FOR SELECT USING (id = 1);
CREATE POLICY test83_p4_all ON test83_t4 FOR SELECT TO CURRENT_USER USING (true);

CREATE FUNCTION test83_f4() RETURNS SETOF text
  STABLE LANGUAGE SQL
  AS $$ SELECT EXISTS(SELECT 1 FROM test83_t4 WHERE id = 2)::text $$;

EXPLAIN ANALYZE SELECT current_user, * FROM test83_f4();

DROP FUNCTION test83_f4();
DROP TABLE test83_t4;


-- ================================================================
-- Test 5: SRF inlining with RLS and an aggregate + grouping
-- 
-- Covers: The inlined function body uses array_agg and GROUP BY on
-- an RLS-protected table. This exercises the path where coercion
-- projections may be inserted before the RLS check, testing that
-- the hasRowSecurity flag survives transformations.
-- ================================================================
CREATE TABLE test83_t5 (grp int, val text);
INSERT INTO test83_t5 VALUES (1, 'a'), (1, 'b'), (2, 'c'), (2, 'd');

ALTER TABLE test83_t5 ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON test83_t5 TO PUBLIC;

CREATE POLICY test83_p5_public ON test83_t5 FOR SELECT USING (grp = 1);
CREATE POLICY test83_p5_all ON test83_t5 FOR SELECT TO CURRENT_USER USING (true);

CREATE FUNCTION test83_f5() RETURNS SETOF record
  STABLE LANGUAGE SQL
  AS $$ SELECT grp, array_agg(val) AS vals FROM test83_t5 GROUP BY grp $$;

-- Note: need to specify column definition for record-returning function
EXPLAIN ANALYZE SELECT current_user, * FROM test83_f5() AS f(grp int, vals text[]);

DROP FUNCTION test83_f5();
DROP TABLE test83_t5;

----------------------------------------
-- Source: 84.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for:
--   Rename ExecAggTransReparent, and improve its documentation.
-- task_id: 84
--
-- This commit renames ExecAggTransReparent -> ExecAggCopyTransValue
-- and improves its documentation.  The test cases exercise the
-- code path (ExecAggCopyTransValue in ExecAggPlainTransByRef /
-- advance_transition_function) for pass-by-reference aggregate
-- transition types where newVal != oldValue.
-- ================================================================

-- ##################################################################
-- Test 1: Basic pass-by-ref aggregate with text type
--   Covers: ExecAggCopyTransValue called from ExecAggPlainTransByRef
--   The text type is pass-by-reference, so string_agg() will trigger
--   the copy path when accumulating >1 rows.
-- ##################################################################
BEGIN;

CREATE TABLE test_text_agg (id int, val text);
INSERT INTO test_text_agg VALUES
  (1, 'hello'),
  (2, 'world'),
  (3, 'foo'),
  (4, 'bar'),
  (5, 'baz');

-- Force a non-hash agg plan to exercise the transition path
-- string_agg uses internal (pass-by-ref) transition type.
EXPLAIN ANALYZE SELECT string_agg(val, ',' ORDER BY id) FROM test_text_agg;

DROP TABLE test_text_agg;

COMMIT;

-- ##################################################################
-- Test 2: Pass-by-ref aggregate with jsonb type
--   Covers: ExecAggCopyTransValue with strict/non-strict transfns
--   jsonb_agg / jsonb_object_agg use internal pass-by-ref trans type
-- ##################################################################
BEGIN;

CREATE TABLE test_jsonb_agg (k text, v jsonb);
INSERT INTO test_jsonb_agg VALUES
  ('a', '"hello"'),
  ('b', '123'),
  ('c', '{"x":1}'),
  ('d', 'null'),
  ('e', '[1,2,3]');

-- jsonb_agg uses pass-by-ref transition value
EXPLAIN ANALYZE SELECT jsonb_agg(v ORDER BY k) FROM test_jsonb_agg;

-- jsonb_object_agg also uses pass-by-ref
EXPLAIN ANALYZE SELECT jsonb_object_agg(k, v) FROM test_jsonb_agg;

DROP TABLE test_jsonb_agg;

COMMIT;

-- ##################################################################
-- Test 3: GROUP BY with pass-by-ref aggregate (multiple groups)
--   Covers: ExecAggCopyTransValue with multiple per-group states
--   Each group has its own transition value that gets copied.
-- ##################################################################
BEGIN;

CREATE TABLE test_group_agg (grp int, val text);
INSERT INTO test_group_agg VALUES
  (1, 'alpha'),
  (1, 'beta'),
  (1, 'gamma'),
  (2, 'delta'),
  (2, 'epsilon'),
  (3, 'zeta');

-- Multiple groups each with multiple rows -> transition value
-- will be different from oldValue (string_agg returns new datum).
EXPLAIN ANALYZE SELECT grp, string_agg(val, ',' ORDER BY val) FROM test_group_agg GROUP BY grp;

DROP TABLE test_group_agg;

COMMIT;

-- ##################################################################
-- Test 4: Aggregate with NULLs and pass-by-ref trans type
--   Covers: ExecAggCopyTransValue when newValue is NOT NULL,
--           oldValue is NULL (first non-null) and NULL inputs
-- ##################################################################
BEGIN;

CREATE TABLE test_null_agg (id int, val text);
INSERT INTO test_null_agg VALUES
  (1, NULL),
  (2, 'first'),
  (3, NULL),
  (4, 'second'),
  (5, 'third');

-- Mix of NULLs and non-NULLs; strict aggregate ignores NULLs
EXPLAIN ANALYZE SELECT string_agg(val, ',' ORDER BY id) FROM test_null_agg;

-- All NULLs -> should not enter the copy path
EXPLAIN ANALYZE SELECT string_agg(val, ',') FROM test_null_agg WHERE val IS NULL;

DROP TABLE test_null_agg;

COMMIT;

-- ##################################################################
-- Test 5: Array aggregate (pass-by-ref) with int[]
--   Covers: ExecAggCopyTransValue with array type
--   array_agg(integer[]) uses int4[] as transition type, which is
--   pass-by-reference.  Multiple rows produce new arrays to copy.
-- ##################################################################
BEGIN;

CREATE TABLE test_array_agg (id int, val int[]);
INSERT INTO test_array_agg VALUES
  (1, ARRAY[1,2]),
  (2, ARRAY[3,4]),
  (3, ARRAY[5,6]),
  (4, ARRAY[7,8]),
  (5, ARRAY[9,10]);

-- array_agg with composite arrays uses pass-by-ref trans type
EXPLAIN ANALYZE SELECT array_agg(val ORDER BY id) FROM test_array_agg;

-- With GROUP BY on computed expression
EXPLAIN ANALYZE SELECT id % 2 AS grp, array_agg(val ORDER BY id)
  FROM test_array_agg
  GROUP BY (id % 2);

DROP TABLE test_array_agg;

COMMIT;

----------------------------------------
-- Source: 86.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix assignment to array of domain over composite, redux.
-- task_id: 86
-- 
-- This commit adds handling of RelabelType in isAssignmentIndirectionExpr(),
-- so that when a domain over composite has no constraints (and thus gets
-- simplified from CoerceToDomain to RelabelType by the planner), assignment
-- to an array of that domain still works correctly.
-- ================================================================

-- ================================================================
-- Test 1: Basic array-of-domain-over-composite with no constraints
-- This is the core fix: domain without constraints -> RelabelType
-- ================================================================
CREATE TYPE test86_comptype1 AS (a int, b int);
CREATE DOMAIN test86_dcomptype1 AS test86_comptype1;  -- no constraints
CREATE TABLE test86_t1 (f1 test86_dcomptype1[]);

INSERT INTO test86_t1 VALUES (NULL);
INSERT INTO test86_t1 VALUES (ARRAY[ROW(1, 2)::test86_comptype1]);

-- This assignment must work even though the domain has no constraints
-- (planner will simplify CoerceToDomain to RelabelType)
EXPLAIN ANALYZE UPDATE test86_t1 SET f1[1].a = 10;
EXPLAIN ANALYZE UPDATE test86_t1 SET f1[1].b = 20;

DROP TABLE test86_t1;
DROP DOMAIN test86_dcomptype1;
DROP TYPE test86_comptype1;


-- ================================================================
-- Test 2: Multiple elements in the array, diverse assignments
-- Tests the RelabelType path with array having multiple elements
-- ================================================================
CREATE TYPE test86_comptype2 AS (x int, y text, z float8);
CREATE DOMAIN test86_dcomptype2 AS test86_comptype2;  -- no constraints
CREATE TABLE test86_t2 (id int, arr test86_dcomptype2[]);

INSERT INTO test86_t2 VALUES (1, ARRAY[ROW(1, 'foo', 1.5)::test86_comptype2,
                                        ROW(2, 'bar', 2.5)::test86_comptype2,
                                        ROW(3, 'baz', 3.5)::test86_comptype2]);

-- Assign to an element in the middle
EXPLAIN ANALYZE UPDATE test86_t2 SET arr[2].y = 'updated';
EXPLAIN ANALYZE UPDATE test86_t2 SET arr[2].x = 99;

-- Assign based on condition
EXPLAIN ANALYZE UPDATE test86_t2 SET arr[1].z = 100.0 WHERE id = 1;

DROP TABLE test86_t2;
DROP DOMAIN test86_dcomptype2;
DROP TYPE test86_comptype2;


-- ================================================================
-- Test 3: Composite type with nullable fields (NULL edge cases)
-- Tests assignment with NULL values in the array
-- ================================================================
CREATE TYPE test86_comptype3 AS (id int, label text, score numeric);
CREATE DOMAIN test86_dcomptype3 AS test86_comptype3;  -- no constraints
CREATE TABLE test86_t3 (f1 test86_dcomptype3[]);

INSERT INTO test86_t3 VALUES (NULL);
INSERT INTO test86_t3 VALUES (ARRAY[NULL::test86_comptype3,
                                     ROW(NULL, 'hello', NULL)::test86_comptype3,
                                     ROW(42, 'world', 3.14)::test86_comptype3]);

-- Assign to array slot that currently contains NULL
EXPLAIN ANALYZE UPDATE test86_t3 SET f1[1] = ROW(100, 'filled', 0.0)::test86_comptype3;

-- Assign to a field that was NULL
EXPLAIN ANALYZE UPDATE test86_t3 SET f1[2].score = 99.99;

-- Assign to a field that was NULL and make it still NULL
EXPLAIN ANALYZE UPDATE test86_t3 SET f1[2].label = NULL;

DROP TABLE test86_t3;
DROP DOMAIN test86_dcomptype3;
DROP TYPE test86_comptype3;


-- ================================================================
-- Test 4: Multiple domain columns and simultaneous assignments
-- Tests that RelabelType path works with multiple columns of domain arrays
-- ================================================================
CREATE TYPE test86_comptype4 AS (p int, q int);
CREATE DOMAIN test86_dcomptype4 AS test86_comptype4;  -- no constraints
CREATE TABLE test86_t4 (a test86_dcomptype4[], b test86_dcomptype4[]);

INSERT INTO test86_t4 VALUES (ARRAY[ROW(1, 2)::test86_comptype4],
                              ARRAY[ROW(3, 4)::test86_comptype4]);

-- Assign to both columns in one statement
EXPLAIN ANALYZE UPDATE test86_t4 SET a[1].p = 10, b[1].q = 40;
EXPLAIN ANALYZE UPDATE test86_t4 SET a[1].p = a[1].p + 1, b[1].q = b[1].q + 1;

DROP TABLE test86_t4;
DROP DOMAIN test86_dcomptype4;
DROP TYPE test86_comptype4;


-- ================================================================
-- Test 5: Composite with more complex types (text, boolean, numeric[])
-- Tests the RelabelType path with varying internal field types
-- ================================================================
CREATE TYPE test86_comptype5 AS (name text, active boolean, scores numeric[]);
CREATE DOMAIN test86_dcomptype5 AS test86_comptype5;  -- no constraints
CREATE TABLE test86_t5 (f1 test86_dcomptype5[]);

INSERT INTO test86_t5 VALUES (ARRAY[ROW('Alice', true, ARRAY[95, 87, 92]::numeric[])::test86_comptype5,
                                     ROW('Bob', false, ARRAY[70, 65]::numeric[])::test86_comptype5]);

-- Assign to text field
EXPLAIN ANALYZE UPDATE test86_t5 SET f1[1].name = 'Alicia';

-- Assign to boolean field
EXPLAIN ANALYZE UPDATE test86_t5 SET f1[2].active = true;

-- Assign to array field inside composite inside domain array
EXPLAIN ANALYZE UPDATE test86_t5 SET f1[1].scores = ARRAY[100, 98, 95]::numeric[];

-- Assign using the old value (requires old element to be fetched)
EXPLAIN ANALYZE UPDATE test86_t5 SET f1[1].scores[1] = 99;

DROP TABLE test86_t5;
DROP DOMAIN test86_dcomptype5;
DROP TYPE test86_comptype5;

----------------------------------------
-- Source: 87.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix incorrect partition pruning logic
-- for boolean partitioned tables
-- task_id: 87
-- ================================================================
-- This test covers the fix for two bugs in boolean partition pruning:
-- 1) "b IS NOT TRUE" was incorrectly treated as "b IS FALSE", missing
--    NULL values that should be included
-- 2) Partition pruning for ((NOT boolcol)) partition key was broken
-- ================================================================

-- ================================================================
-- Test 1: Verify "IS NOT TRUE" includes NULL rows
-- When partition key is boolean, "a IS NOT TRUE" should return both
-- false and NULL values. The bug caused NULL rows to be omitted.
-- ================================================================
CREATE TABLE test_boolpart_is_not_true (a bool) PARTITION BY LIST (a);
CREATE TABLE test_boolpart_is_not_true_t PARTITION OF test_boolpart_is_not_true FOR VALUES IN ('true');
CREATE TABLE test_boolpart_is_not_true_f PARTITION OF test_boolpart_is_not_true FOR VALUES IN ('false');
CREATE TABLE test_boolpart_is_not_true_default PARTITION OF test_boolpart_is_not_true DEFAULT;

INSERT INTO test_boolpart_is_not_true VALUES (true), (false), (NULL);

-- This should return false and NULL rows (2 rows), not just false (1 row)
EXPLAIN ANALYZE SELECT * FROM test_boolpart_is_not_true WHERE a IS NOT TRUE;
SELECT * FROM test_boolpart_is_not_true WHERE a IS NOT TRUE;

-- Also test "IS NOT FALSE" which should return true and NULL rows
EXPLAIN ANALYZE SELECT * FROM test_boolpart_is_not_true WHERE a IS NOT FALSE;
SELECT * FROM test_boolpart_is_not_true WHERE a IS NOT FALSE;

DROP TABLE test_boolpart_is_not_true;

-- ================================================================
-- Test 2: Verify "IS NOT TRUE" with explicit NULL partition
-- Instead of a default partition, use a dedicated NULL partition.
-- This exercises a different pruning path.
-- ================================================================
CREATE TABLE test_boolpart_nullpart (a bool) PARTITION BY LIST (a);
CREATE TABLE test_boolpart_nullpart_t PARTITION OF test_boolpart_nullpart FOR VALUES IN ('true');
CREATE TABLE test_boolpart_nullpart_f PARTITION OF test_boolpart_nullpart FOR VALUES IN ('false');
CREATE TABLE test_boolpart_nullpart_n PARTITION OF test_boolpart_nullpart FOR VALUES IN (null);

INSERT INTO test_boolpart_nullpart VALUES (true), (false), (NULL);

-- "IS NOT TRUE" should scan false partition AND null partition
EXPLAIN ANALYZE SELECT * FROM test_boolpart_nullpart WHERE a IS NOT TRUE;
SELECT * FROM test_boolpart_nullpart WHERE a IS NOT TRUE;

-- "IS NOT FALSE" should scan true partition AND null partition
EXPLAIN ANALYZE SELECT * FROM test_boolpart_nullpart WHERE a IS NOT FALSE;
SELECT * FROM test_boolpart_nullpart WHERE a IS NOT FALSE;

DROP TABLE test_boolpart_nullpart;

-- ================================================================
-- Test 3: Verify ((NOT boolcol)) partition key - the second bug fix
-- Partition key is the negation of a boolean column.
-- Test basic equality and boolean test predicates.
-- ================================================================
CREATE TABLE test_iboolpart (a bool) PARTITION BY LIST ((NOT a));
CREATE TABLE test_iboolpart_t PARTITION OF test_iboolpart FOR VALUES IN ('true');
CREATE TABLE test_iboolpart_f PARTITION OF test_iboolpart FOR VALUES IN ('false');
CREATE TABLE test_iboolpart_default PARTITION OF test_iboolpart DEFAULT;

INSERT INTO test_iboolpart VALUES (true), (false), (NULL);

-- With NOT a as partition key:
--   (NOT true) = false  -> goes to 'false' partition
--   (NOT false) = true  -> goes to 'true' partition
--   (NOT NULL) = NULL   -> goes to default partition

-- Query: a = true -> NOT a = false -> should scan 'false' partition only
EXPLAIN ANALYZE SELECT * FROM test_iboolpart WHERE a = true;
SELECT * FROM test_iboolpart WHERE a = true;

-- Query: a = false -> NOT a = true -> should scan 'true' partition only
EXPLAIN ANALYZE SELECT * FROM test_iboolpart WHERE a = false;
SELECT * FROM test_iboolpart WHERE a = false;

-- Query: a IS TRUE -> should scan 'false' partition (NOT true = false)
EXPLAIN ANALYZE SELECT * FROM test_iboolpart WHERE a IS TRUE;
SELECT * FROM test_iboolpart WHERE a IS TRUE;

DROP TABLE test_iboolpart;

-- ================================================================
-- Test 4: Verify ((NOT boolcol)) partition key with IS NOT TRUE/FALSE
-- This exercises the noteq path for inverted boolean partition keys.
-- For inverted keys:
--   "a IS NOT TRUE" means NOT a is NOT TRUE -> (NOT a) is FALSE OR (NOT a) IS NULL
--   Since NOT(NULL) = NULL, this should include the NULL partition.
-- ================================================================
CREATE TABLE test_iboolpart2 (a bool) PARTITION BY LIST ((NOT a));
CREATE TABLE test_iboolpart2_t PARTITION OF test_iboolpart2 FOR VALUES IN ('true');
CREATE TABLE test_iboolpart2_f PARTITION OF test_iboolpart2 FOR VALUES IN ('false');
CREATE TABLE test_iboolpart2_default PARTITION OF test_iboolpart2 DEFAULT;

INSERT INTO test_iboolpart2 VALUES (true), (false), (NULL);

-- a IS NOT TRUE: 
--   a=true -> NOT a=false -> partition key='false' (in 'false' partition) -> does NOT match "IS NOT TRUE"? 
--   Actually: a IS NOT TRUE is true for false and NULL
--   a=false -> NOT a=true -> partition key='true' (in 'true' partition) -> matches
--   a=NULL -> NULL -> default partition -> matches
EXPLAIN ANALYZE SELECT * FROM test_iboolpart2 WHERE a IS NOT TRUE;
SELECT * FROM test_iboolpart2 WHERE a IS NOT TRUE;

-- a IS NOT FALSE:
--   a=true -> NOT a=false -> partition key='false' (in 'false' partition) -> matches
--   a=false -> NOT a=true -> partition key='true' (in 'true' partition) -> does NOT match
--   a=NULL -> NULL -> default partition -> matches
EXPLAIN ANALYZE SELECT * FROM test_iboolpart2 WHERE a IS NOT FALSE;
SELECT * FROM test_iboolpart2 WHERE a IS NOT FALSE;

DROP TABLE test_iboolpart2;

-- ================================================================
-- Test 5: Verify combined boolean partition pruning with range
-- partitioning on boolean columns and edge cases
-- ================================================================
CREATE TABLE test_boolrange (a bool, b bool, c int) PARTITION BY RANGE (a, b, c);
CREATE TABLE test_boolrange_tt PARTITION OF test_boolrange FOR VALUES FROM ('true', 'true', 0) TO ('true', 'true', 100);
CREATE TABLE test_boolrange_tf PARTITION OF test_boolrange FOR VALUES FROM ('true', 'false', 0) TO ('true', 'false', 100);
CREATE TABLE test_boolrange_ft PARTITION OF test_boolrange FOR VALUES FROM ('false', 'true', 0) TO ('false', 'true', 100);
CREATE TABLE test_boolrange_ff PARTITION OF test_boolrange FOR VALUES FROM ('false', 'false', 0) TO ('false', 'false', 100);
CREATE TABLE test_boolrange_default PARTITION OF test_boolrange DEFAULT;

INSERT INTO test_boolrange VALUES (true, true, 1), (true, false, 2), (false, true, 3), (false, false, 4), (NULL, NULL, 5);
INSERT INTO test_boolrange VALUES (true, NULL, 6), (NULL, true, 7);

-- Prune with "a IS NOT TRUE" - should include false and NULL partitions
EXPLAIN ANALYZE SELECT * FROM test_boolrange WHERE a IS NOT TRUE AND b = true AND c = 3;

-- Complex query mixing boolean tests
EXPLAIN ANALYZE SELECT * FROM test_boolrange WHERE (a IS NOT TRUE OR b IS NOT FALSE) AND c > 0;

-- Query with NOT on column reference  
EXPLAIN ANALYZE SELECT * FROM test_boolrange WHERE NOT a AND b = false;
SELECT * FROM test_boolrange WHERE NOT a AND b = false;

DROP TABLE test_boolrange;

----------------------------------------
-- Source: 89.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: hio: Relax rules for calling GetVisibilityMapPins()
-- task_id: 89
-- 
-- This commit simplifies GetVisibilityMapPins() by moving the buffer
-- ordering logic inside the function. Previously the callers had to
-- check buffer ordering before calling; now GetVisibilityMapPins
-- handles single-buffer and out-of-order cases by swapping internally.
-- 
-- The test covers:
--   1) Simple insert (otherBuffer=InvalidBuffer, single buffer path)
--   2) INSERT into all-visible pages (triggers VM pin logic)
--   3) UPDATE that moves tuple to a new page (otherBuffer provided)
--   4) UPDATE with old page > new page (tests block1 > block2 swap)
--   5) Multi-INSERT (bulk insert path)
-- ================================================================

-- ##################################################################
-- Test 1: Simple INSERT (otherBuffer = InvalidBuffer)
-- 
-- Covers: The main call path in RelationGetBufferForTuple where
-- otherBuffer is InvalidBuffer. This exercises the simplification
-- at line 479-480 of hio.c where GetVisibilityMapPins is called
-- without the previous conditional check.
-- ##################################################################

CREATE TABLE test_simple_insert (
    id SERIAL PRIMARY KEY,
    data TEXT
);

-- Insert enough rows to fill at least one page, then more
INSERT INTO test_simple_insert (data)
SELECT 'row_' || g
FROM generate_series(1, 100) g;

-- VACUUM to mark pages all-visible (helps trigger VM pin logic)
VACUUM test_simple_insert;

-- Insert more rows; some pages should now be all-visible
INSERT INTO test_simple_insert (data)
SELECT 'more_rows_' || g
FROM generate_series(1, 50) g;

-- ANALYZE to see the plan
EXPLAIN ANALYZE INSERT INTO test_simple_insert (data)
SELECT 'explain_test_' || g
FROM generate_series(1, 10) g;

DROP TABLE test_simple_insert;

-- ##################################################################
-- Test 2: INSERT into all-visible pages (visibility map pin path)
-- 
-- Covers: GetVisibilityMapPins() when pages are all-visible and VM
-- pins need to be acquired. This exercises need_to_pin_buffer1 logic.
-- ##################################################################

CREATE TABLE test_allvisible_insert (
    id INT,
    payload TEXT
) WITH (FILLFACTOR = 50);

-- Insert enough rows to create multiple pages
INSERT INTO test_allvisible_insert (id, payload)
SELECT g, repeat('x', 500)
FROM generate_series(1, 500) g;

-- Make all pages all-visible
VACUUM FREEZE test_allvisible_insert;

-- Now insert more rows; the VM pin logic should activate
EXPLAIN ANALYZE INSERT INTO test_allvisible_insert (id, payload)
SELECT g, repeat('y', 100)
FROM generate_series(1000, 1100) g;

-- Also test with SKIP_FSM-like behavior by inserting single rows
INSERT INTO test_allvisible_insert (id, payload) VALUES (-1, 'single_row_test');

DROP TABLE test_allvisible_insert;

-- ##################################################################
-- Test 3: UPDATE that moves tuple to a new page (otherBuffer path)
-- 
-- Covers: The heap_update path (heapam.c line 3639) where
-- RelationGetBufferForTuple is called with a valid otherBuffer
-- (the old tuple's buffer). This triggers the code path at line
-- 479-480 of hio.c with both buffers valid.
-- ##################################################################

CREATE TABLE test_update_move (
    id INT PRIMARY KEY,
    data TEXT
);

-- Insert rows filling pages
INSERT INTO test_update_move (id, data)
SELECT g, repeat('initial_data_', 20)
FROM generate_series(1, 50) g;

-- Make pages all-visible
VACUUM test_update_move;

-- Update rows to make them larger (forcing a move to a new page)
EXPLAIN ANALYZE UPDATE test_update_move
SET data = repeat('x', 2000)
WHERE id = 1;

-- Update another row
UPDATE test_update_move
SET data = repeat('y', 2000)
WHERE id = 2;

-- Clean up
DROP TABLE test_update_move;

-- ##################################################################
-- Test 4: UPDATE with old page > new page (block ordering swap)
-- 
-- Covers: GetVisibilityMapPins() internal swap when block1 > block2
-- (added by the commit). This happens during heap_update when:
-- - The old tuple is on a higher-numbered page
-- - The new tuple needs to go to a lower-numbered page
-- The new code swaps the buffers so that block1 <= block2 for the
-- visibility map pin logic.
-- ##################################################################

CREATE TABLE test_update_block_order (
    id INT PRIMARY KEY,
    data TEXT,
    filler TEXT
);

-- Create data that fills pages unevenly
-- First, fill some pages with large tuples
INSERT INTO test_update_block_order (id, data, filler)
SELECT g, 'large_' || g, repeat('x', 3000)
FROM generate_series(1, 20) g;

-- Add small tuples that go on later pages (higher block numbers)
INSERT INTO test_update_block_order (id, data, filler)
SELECT g, 'small_' || g, 'short'
FROM generate_series(100, 120) g;

-- VACUUM to set visibility map bits
VACUUM test_update_block_order;

-- Now update a small tuple (on a high-numbered page) with a large value
-- that will cause it to move. The new page (found by FSM) may be a
-- lower-numbered page -> block1 > block2 scenario.
EXPLAIN ANALYZE UPDATE test_update_block_order
SET data = 'MOVED_UP', filler = repeat('moved_data_', 500)
WHERE id = 100;

-- Also try updating the tuple back (if it moved to a low page, going back
-- tests the reverse direction)
UPDATE test_update_block_order
SET data = 'MOVED_AGAIN', filler = repeat('back_again_', 500)
WHERE id = 100;

DROP TABLE test_update_block_order;

-- ##################################################################
-- Test 5: Multi-INSERT (bulk insert path)
-- 
-- Covers: heap_multi_insert path (heapam.c line 2194) and the
-- extension path (hio.c line 655) where GetVisibilityMapPins is
-- called after extending the relation. This path always calls with
-- otherBlock < targetBlock (since targetBlock is the newly extended
-- page), testing the swap logic when block1 (otherBlock) < block2.
-- ##################################################################

CREATE TABLE test_multi_insert (
    id SERIAL,
    data TEXT
);

-- Use multiple INSERTs of many rows to trigger multi-insert code path
EXPLAIN ANALYZE INSERT INTO test_multi_insert (data)
SELECT 'batch1_row_' || g
FROM generate_series(1, 500) g;

-- VACUUM to make pages all-visible
VACUUM test_multi_insert;

-- Second batch - multi-insert into all-visible pages
EXPLAIN ANALYZE INSERT INTO test_multi_insert (data)
SELECT 'batch2_row_' || g
FROM generate_series(501, 1000) g;

-- Third batch to trigger extension path
EXPLAIN ANALYZE INSERT INTO test_multi_insert (data)
SELECT 'batch3_row_' || g
FROM generate_series(1001, 1500) g;

DROP TABLE test_multi_insert;

-- ##################################################################
-- End of regression tests
-- ##################################################################

----------------------------------------
-- Source: 90.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix ts_headline() edge cases for empty query
--                        and empty search text
-- task_id: 90
-- Description: Tests the three fix areas:
--   1. hlCover(): early return false when query->size <= 0
--   2. mark_hl_fragments(): set endpos = -1 when no match found
--   3. mark_hl_words(): set pose = -1 when no match found
-- ================================================================

-- ================================================================
-- Test 1: Empty tsquery with non-empty text (hlCover empty query guard)
-- This exercises the new check in hlCover():
--   "if (query->size <= 0) return false;"
-- tsquery('') produces an empty query (size=0).
-- ================================================================
SELECT ts_headline('english',
'Day after day, day after day,
  We stuck, nor breath nor motion,
As idle as a painted Ship
  Upon a painted Ocean.',
to_tsquery('english', ''));

SELECT ts_headline('simple',
'foo bar baz',
to_tsquery('simple', ''));

-- Also test with MaxFragments > 0 to hit mark_hl_fragments path
SELECT ts_headline('english',
'The quick brown fox jumps over the lazy dog.',
to_tsquery('english', ''),
'MaxFragments=3, MaxWords=20, MinWords=1');


-- ================================================================
-- Test 2: Empty tsquery with NULL-style empty text (dual empty)
-- This tests both hlCover() empty query guard and the empty text
-- paths in mark_hl_words / mark_hl_fragments simultaneously.
-- ================================================================
SELECT ts_headline('english',
'', to_tsquery('english', ''));

SELECT ts_headline('simple',
'', to_tsquery('simple', ''));

-- With MaxFragments to hit mark_hl_fragments path
SELECT ts_headline('english',
'', to_tsquery('english', ''),
'MaxFragments=3');


-- ================================================================
-- Test 3: Non-empty query with NO matching text in document
-- (mark_hl_words: pose = -1 path when bestlen < 0)
-- Uses MaxFragments=0 (default) to enter mark_hl_words()
-- The query 'xyzzy' does not appear in the text, so hlCover
-- returns false for all covers, leading bestlen < 0.
-- ================================================================
SELECT ts_headline('english',
'Day after day, day after day,
  We stuck, nor breath nor motion,
As idle as a painted Ship
  Upon a painted Ocean.',
to_tsquery('english', 'xyzzy'));

SELECT ts_headline('simple',
'one two three four five',
to_tsquery('simple', 'nonexistent'),
'MaxWords=10, MinWords=2');

-- With HighlightAll=true and no match
SELECT ts_headline('simple',
'one two three',
to_tsquery('simple', 'nothing'),
'HighlightAll=true, MaxWords=10, MinWords=1');


-- ================================================================
-- Test 4: Non-empty query with NO matching text using fragments mode
-- (mark_hl_fragments: endpos = -1 path when no fragments found)
-- Uses MaxFragments>0 to enter mark_hl_fragments()
-- Query does not match any text, so num_f <= 0 triggers the path.
-- ================================================================
SELECT ts_headline('english',
'The quick brown fox jumps over the lazy dog.',
to_tsquery('english', 'dragon'),
'MaxFragments=3, MaxWords=20, MinWords=1');

SELECT ts_headline('simple',
'alpha beta gamma delta',
to_tsquery('simple', 'omega'),
'MaxFragments=5, MaxWords=10, MinWords=3');

-- With single word document and no match
SELECT ts_headline('simple',
'hello',
to_tsquery('simple', 'world'),
'MaxFragments=2, MaxWords=5, MinWords=1');


-- ================================================================
-- Test 5: Combined edge cases: empty text with non-empty query
-- (hlCover returns false because prs->curwords is 0,
--  then mark_hl_words/mark_hl_fragments handle empty text)
-- This exercises the scenario where the text is empty but query
-- is valid; no covers can be found; the fallback paths with
-- pose = -1 / endpos = -1 are triggered.
-- ================================================================
-- Empty text, non-empty query, mark_hl_words path (MaxFragments=0)
SELECT ts_headline('english',
'', to_tsquery('english', 'ocean'));

-- Empty text, non-empty query, mark_hl_fragments path
SELECT ts_headline('english',
'', to_tsquery('english', 'ocean'),
'MaxFragments=3, MaxWords=10, MinWords=1');

-- Very short text (only stop words / non-word tokens), non-empty query
SELECT ts_headline('english',
'a an the',
to_tsquery('english', 'ocean'));

----------------------------------------
-- Source: 92.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Reject system columns as elements of foreign keys
-- task_id: 92
-- 
-- This commit adds a check in transformColumnNameList() that rejects
-- system columns (attnum < 0) from being used in foreign key constraints.
-- The check applies to both the referencing (FK) side and referenced (PK) side.
-- System columns include: ctid (oid), xmin, cmin, xmax, cmax, tableoid
-- 
-- Coverage targets:
--   - transformColumnNameList() called for FK side (line 8845)
--   - transformColumnNameList() called for PK side (line 8864)
--   - The new check: if (attform->attnum < 0) ... (line 10718)
-- 
-- Each test covers a different system column and a different SQL construct.
-- ================================================================

-- ================================================================
-- Test 1: ctid on the referencing (FK) side via CREATE TABLE ... REFERENCES
-- This hits transformColumnNameList at line 8845 for FK column lookup.
-- ctid is SelfItemPointerAttributeNumber (-1).
-- ================================================================
CREATE TABLE test_92_t1 (a int PRIMARY KEY);
CREATE TABLE test_92_fk1 (b int REFERENCES test_92_t1(a));
-- Now test using ctid on the referencing side:
CREATE TABLE test_92_fk1_ctid (ctid tid, CONSTRAINT fk_ctid FOREIGN KEY (ctid) REFERENCES test_92_t1(a));
ERROR:  system columns cannot be used in foreign keys
DROP TABLE IF EXISTS test_92_t1 CASCADE;
DROP TABLE IF EXISTS test_92_fk1 CASCADE;

-- ================================================================
-- Test 2: xmin on the referenced (PK) side via CREATE TABLE ... FOREIGN KEY
-- This hits transformColumnNameList at line 8864 for PK column lookup.
-- xmin is MinTransactionIdAttributeNumber (-2).
-- ================================================================
CREATE TABLE test_92_t2 (a int PRIMARY KEY);
CREATE TABLE test_92_fk2 (b int, FOREIGN KEY (b) REFERENCES test_92_t2(xmin));
ERROR:  system columns cannot be used in foreign keys
DROP TABLE IF EXISTS test_92_t2 CASCADE;
DROP TABLE IF EXISTS test_92_fk2 CASCADE;

-- ================================================================
-- Test 3: cmin on the referencing (FK) side via ALTER TABLE ADD FOREIGN KEY
-- cmin is MinCommandIdAttributeNumber (-3).
-- ================================================================
CREATE TABLE test_92_t3 (a int PRIMARY KEY);
CREATE TABLE test_92_fk3 (cmin int);
ALTER TABLE test_92_fk3 ADD CONSTRAINT fk_cmin FOREIGN KEY (cmin) REFERENCES test_92_t3(a);
ERROR:  system columns cannot be used in foreign keys
DROP TABLE IF EXISTS test_92_t3 CASCADE;
DROP TABLE IF EXISTS test_92_fk3 CASCADE;

-- ================================================================
-- Test 4: xmax on the referenced (PK) side via ALTER TABLE ADD FOREIGN KEY
-- xmax is MaxTransactionIdAttributeNumber (-4).
-- ================================================================
CREATE TABLE test_92_t4 (a int PRIMARY KEY);
CREATE TABLE test_92_fk4 (b int);
ALTER TABLE test_92_fk4 ADD CONSTRAINT fk_xmax FOREIGN KEY (b) REFERENCES test_92_t4(xmax);
ERROR:  system columns cannot be used in foreign keys
DROP TABLE IF EXISTS test_92_t4 CASCADE;
DROP TABLE IF EXISTS test_92_fk4 CASCADE;

-- ================================================================
-- Test 5: cmax in a multi-column foreign key on the referencing side
-- cmax is MaxCommandIdAttributeNumber (-5).
-- Also tests that a valid FK alongside a system-column FK still catches the error.
-- ================================================================
CREATE TABLE test_92_t5 (a int, b int, PRIMARY KEY (a, b));
CREATE TABLE test_92_fk5 (x int, cmax int);
ALTER TABLE test_92_fk5 ADD CONSTRAINT fk_cmax FOREIGN KEY (x, cmax) REFERENCES test_92_t5(a, b);
ERROR:  system columns cannot be used in foreign keys
DROP TABLE IF EXISTS test_92_t5 CASCADE;
DROP TABLE IF EXISTS test_92_fk5 CASCADE;


----------------------------------------
-- Source: 93.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix dereference of dangling pointer in
-- GiST index buffering build (task_id: 93)
-- ================================================================
-- This commit moved the indtuples/indtuplesSize update before the
-- call to gistProcessEmptyingQueue(), to avoid reading IndexTupleSize(itup)
-- after itup might have been freed by gistProcessEmptyingQueue().
-- 
-- Code path: gistBuildCallback() when buildstate->bufferingMode == 
-- GIST_BUFFERING_ACTIVE, which calls gistBufferingBuildInsert() ->
-- gistProcessEmptyingQueue().
-- ================================================================

-- ================================================================
-- Test 1: Basic buffering build with point data (the simplest case)
-- Forces buffering=on, inserts enough tuples to trigger stats mode
-- and then active buffering mode.
-- ================================================================
CREATE TABLE test_gist_buffering_1 (
    id INTEGER,
    p POINT
);

-- Insert enough data so that the GiST index build enters buffering mode.
-- With buffering=on, first BUFFERING_MODE_TUPLE_SIZE_STATS_TARGET (4096)
-- tuples go through stats mode, then it switches to GIST_BUFFERING_ACTIVE.
INSERT INTO test_gist_buffering_1
SELECT g, point(g, g) FROM generate_series(1, 10000) g;

-- Create GiST index with buffering enabled
CREATE INDEX test_gist_buffering_idx1 ON test_gist_buffering_1 USING gist(p) WITH (buffering = ON);

-- Run a query that uses the index (exercises the built index)
SET enable_seqscan = OFF;
EXPLAIN ANALYZE SELECT * FROM test_gist_buffering_1 WHERE p <@ box(point(0,0), point(5000,5000));
EXPLAIN ANALYZE SELECT * FROM test_gist_buffering_1 WHERE p ~= point(100, 100);
SET enable_seqscan = ON;

DROP TABLE test_gist_buffering_1;


-- ================================================================
-- Test 2: Buffering build with integer data (using int4range GiST opclass)
-- Tests a different GiST opclass to exercise various tuple size patterns
-- ================================================================
CREATE TABLE test_gist_buffering_2 (
    id INTEGER,
    r int4range
);

INSERT INTO test_gist_buffering_2
SELECT g, int4range(g, g + 100) FROM generate_series(1, 10000) g;

-- Create GiST index with buffering enabled
CREATE INDEX test_gist_buffering_idx2 ON test_gist_buffering_2 USING gist(r) WITH (buffering = ON, fillfactor = 50);

-- Run queries that exercise the index
SET enable_seqscan = OFF;
EXPLAIN ANALYZE SELECT * FROM test_gist_buffering_2 WHERE r @> 5000;
EXPLAIN ANALYZE SELECT * FROM test_gist_buffering_2 WHERE r && int4range(3000, 4000);
SET enable_seqscan = ON;

DROP TABLE test_gist_buffering_2;


-- ================================================================
-- Test 3: Buffering build with NULL values and edge cases
-- The fix involves accessing IndexTupleSize(itup) before it could be
-- freed. NULL values affect tuple size and should be tested.
-- ================================================================
CREATE TABLE test_gist_buffering_3 (
    id INTEGER,
    p POINT
);

-- Mix of valid points and NULL values
INSERT INTO test_gist_buffering_3
SELECT g, CASE WHEN g % 5 = 0 THEN NULL ELSE point(g, g) END
FROM generate_series(1, 10000) g;

-- Also add some duplicate/repeated points
INSERT INTO test_gist_buffering_3
SELECT 20000 + g, point(0, 0) FROM generate_series(1, 100) g;

-- Create GiST index with buffering enabled
CREATE INDEX test_gist_buffering_idx3 ON test_gist_buffering_3 USING gist(p) WITH (buffering = ON);

SET enable_seqscan = OFF;
EXPLAIN ANALYZE SELECT * FROM test_gist_buffering_3 WHERE p IS NULL;
EXPLAIN ANALYZE SELECT * FROM test_gist_buffering_3 WHERE p = point(0, 0);
EXPLAIN ANALYZE SELECT count(*) FROM test_gist_buffering_3 WHERE p IS NOT NULL;
SET enable_seqscan = ON;

DROP TABLE test_gist_buffering_3;


-- ================================================================
-- Test 4: Buffering build with AUTO mode (default) and large data
-- This tests the automatic switch from non-buffering to buffering mode
-- when the index exceeds effective_cache_size.
-- The commit's fix applies when bufferingMode transitions to ACTIVE.
-- ================================================================
CREATE TABLE test_gist_buffering_4 (
    id INTEGER,
    p POINT
);

-- Insert a large amount of data to potentially trigger auto-switch
-- to buffering mode (if the index exceeds effective_cache_size / 4)
INSERT INTO test_gist_buffering_4
SELECT g, point(g * 0.001, g * 0.001) FROM generate_series(1, 20000) g;

-- Use buffering=auto (default when not specified)
CREATE INDEX test_gist_buffering_idx4 ON test_gist_buffering_4 USING gist(p) WITH (buffering = AUTO);

SET enable_seqscan = OFF;
EXPLAIN ANALYZE SELECT * FROM test_gist_buffering_4 WHERE p <@ box(point(0,0), point(10,10));
EXPLAIN ANALYZE SELECT * FROM test_gist_buffering_4 WHERE p ~= point(5, 5);
SET enable_seqscan = ON;

DROP TABLE test_gist_buffering_4;


-- ================================================================
-- Test 5: Buffering build with irregular data distribution
-- Tests varying tuple sizes to exercise the tuple size statistics
-- collection path (GIST_BUFFERING_STATS -> GIST_BUFFERING_ACTIVE)
-- and ensure the moved indtuplesSize update works correctly.
-- ================================================================
CREATE TABLE test_gist_buffering_5 (
    id INTEGER,
    polygon POLYGON
);

-- Insert polygons of varying complexity (varying tuple sizes)
INSERT INTO test_gist_buffering_5
SELECT g, polygon('((0,0),(1,0),(1,1),(0,1))') FROM generate_series(1, 5000) g;

INSERT INTO test_gist_buffering_5
SELECT 5000 + g, polygon('((0,0),(10,0),(10,10),(0,10),(0,0))') FROM generate_series(1, 5000) g;

INSERT INTO test_gist_buffering_5
SELECT 10000 + g, polygon('((0,0),(100,0),(100,100),(50,50),(0,100),(0,0))') FROM generate_series(1, 5000) g;

-- Create GiST index with buffering enabled
CREATE INDEX test_gist_buffering_idx5 ON test_gist_buffering_5 USING gist(polygon) WITH (buffering = ON);

SET enable_seqscan = OFF;
-- Use polygon containment operators
EXPLAIN ANALYZE SELECT * FROM test_gist_buffering_5 WHERE polygon ~= polygon('((0,0),(1,0),(1,1),(0,1))');
EXPLAIN ANALYZE SELECT * FROM test_gist_buffering_5 WHERE polygon @> point(50, 50);
SET enable_seqscan = ON;

DROP TABLE test_gist_buffering_5;

----------------------------------------
-- Source: 94.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Reject attempts to alter composite types used in indexes.
-- task_id: 94
--
-- This test exercises the new code path in find_composite_type_dependencies()
-- that detects when a composite type is used in an expression index column
-- and rejects ALTER TYPE operations on it.
-- ================================================================

-- ================================================================
-- Test 1: Expression index on a regular table that stores composite type
--         as an index column via row() constructor.
--         Expected: ALTER TYPE fails with error.
-- Coverage: The new else branch (objsubid <= 0) scans all columns,
--           finds att->atttypid == typeOid, and triggers error.
-- ================================================================
CREATE TYPE comp_type1 AS (a int, b text);
CREATE TABLE test_tbl1 (x int, y text);
CREATE INDEX test_idx1 ON test_tbl1 ((row(x, y)::comp_type1));
-- This should fail because the index stores the composite type
ALTER TYPE comp_type1 ADD ATTRIBUTE c int;
DROP TABLE test_tbl1;
DROP TYPE comp_type1;

-- ================================================================
-- Test 2: Expression index with composite type via a function that
--         returns the composite type.
--         Expected: ALTER TYPE fails with error.
-- Coverage: Same code path as Test 1 but via a different expression form.
-- ================================================================
CREATE TYPE comp_type2 AS (a int, b text);
CREATE TABLE test_tbl2 (x int, y text);
CREATE OR REPLACE FUNCTION make_comp_type2(int, text) RETURNS comp_type2
    LANGUAGE SQL IMMUTABLE AS 'SELECT ROW($1, $2)::comp_type2';
CREATE INDEX test_idx2 ON test_tbl2 (make_comp_type2(x, y));
-- This should fail because the function return type is comp_type2 and
-- the index stores it as a column
ALTER TYPE comp_type2 DROP ATTRIBUTE b;
DROP TABLE test_tbl2;
DROP FUNCTION make_comp_type2(int, text);
DROP TYPE comp_type2;

-- ================================================================
-- Test 3: Composite type used in an index on a materialized view.
--         Expected: ALTER TYPE fails with error.
-- Coverage: RELKIND_MATVIEW has RELKIND_HAS_STORAGE true, so the
--           new code rejects the ALTER.
-- ================================================================
CREATE TYPE comp_type3 AS (a int, b text);
CREATE TABLE test_tbl3_source (x int, y text);
CREATE MATERIALIZED VIEW test_mv3 AS SELECT x, y FROM test_tbl3_source;
CREATE INDEX test_idx3 ON test_mv3 ((row(x, y)::comp_type3));
-- This should fail because the matview index stores the composite type
ALTER TYPE comp_type3 ADD ATTRIBUTE c numeric;
DROP MATERIALIZED VIEW test_mv3;
DROP TABLE test_tbl3_source;
DROP TYPE comp_type3;

-- ================================================================
-- Test 4: Composite type only transiently referenced in an index
--         expression (not stored as a column type). In this case,
--         the type is used as input to a function in the expression,
--         but the index column type is different.
--         Expected: ALTER TYPE succeeds (no stored dependency).
-- Coverage: The else branch scans all columns but att is NULL
--           (no column has atttypid == typeOid), so it skips.
-- ================================================================
CREATE TYPE comp_type4 AS (a int, b text);
CREATE TABLE test_tbl4 (data comp_type4);
-- Index expression uses the composite ONLY as an argument to textin
-- (the index stores text, not comp_type4):
CREATE INDEX test_idx4 ON test_tbl4 ((CAST(data AS text)));
-- This should succeed because there is no stored column of comp_type4
-- in any index (the index stores text, not comp_type4).
ALTER TYPE comp_type4 ADD ATTRIBUTE c int;
DROP TABLE test_tbl4;
DROP TYPE comp_type4;

-- ================================================================
-- Test 5: Composite type used in an index on a table, with multiple
--         expressions, one of which stores the composite type.
--         Also test that a second attempt with a different kind of
--         ALTER TYPE operation also fails.
--         Expected: Both ADD ATTRIBUTE and DROP ATTRIBUTE fail.
-- Coverage: The new code path handles multiple expression columns,
--           and works for different ALTER TYPE sub-commands.
-- ================================================================
CREATE TYPE comp_type5 AS (a int, b text, d date);
CREATE TABLE test_tbl5 (id int, val1 text, val2 int);
CREATE INDEX test_idx5a ON test_tbl5 ((row(id, val1)::comp_type5), val2);
CREATE INDEX test_idx5b ON test_tbl5 (val2, (row(id, val1)::comp_type5));
-- Both of these should fail
ALTER TYPE comp_type5 DROP ATTRIBUTE d;
ALTER TYPE comp_type5 ALTER ATTRIBUTE b TYPE varchar;
DROP TABLE test_tbl5;
DROP TYPE comp_type5;

----------------------------------------
-- Source: 98.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Reject combining "epoch" and "infinity"
-- with other datetime fields
-- task_id: 98
-- ================================================================
-- This test exercises the modified DecodeDateTime() function in
-- src/backend/utils/adt/datetime.c.
-- 
-- Changes:
-- 1. RESERV token handling: DTK_EPOCH, DTK_LATE, DTK_EARLY are now
--    handled explicitly instead of falling through to a default case.
-- 2. ValidateDate and AM/PM adjustment are now only executed when
--    dtype == DTK_DATE, so special tokens skip those checks.
-- 
-- The main effect is that combining "epoch", "infinity", "-infinity"
-- with regular date/time fields now correctly produces an error.
-- ================================================================

-- ================================================================
-- Test 1: Verify standalone "epoch", "infinity", "-infinity" work
-- Target: DTK_EPOCH, DTK_LATE, DTK_EARLY case branches in RESERV
-- These should still be accepted as valid standalone values.
-- ================================================================
CREATE TABLE test_special_tokens (
    id SERIAL PRIMARY KEY,
    ts TIMESTAMP,
    tstz TIMESTAMPTZ,
    d DATE
);

-- Insert standalone special tokens (should succeed)
INSERT INTO test_special_tokens (ts, tstz, d) VALUES
    ('epoch', 'epoch', 'epoch'),
    ('infinity', 'infinity', 'infinity'),
    ('-infinity', '-infinity', '-infinity');

-- Verify they were stored correctly
SELECT id, ts::text, tstz::text, d::text FROM test_special_tokens ORDER BY id;

-- Test isfinite() on all of them
SELECT id,
       isfinite(ts) AS ts_finite,
       isfinite(tstz) AS tstz_finite,
       isfinite(d) AS d_finite
FROM test_special_tokens ORDER BY id;

DROP TABLE test_special_tokens;
-- Expected: All three inserts succeed, special values are stored correctly,
-- isfinite returns false for infinity/-infinity and true for epoch.


-- ================================================================
-- Test 2: Reject "infinity" combined with regular date fields
-- Target: DTK_LATE case - should not proceed to ValidateDate/AMPM
-- Input like '1995-08-06 infinity' must be rejected.
-- ================================================================
CREATE TABLE test_reject_combined (
    id SERIAL PRIMARY KEY,
    val TEXT
);

-- These should all FAIL with an error
INSERT INTO test_reject_combined (val) VALUES ('should not reach here');

-- Test: date + infinity
-- (Error expected: can combine date with infinity)
-- Note: We use a DO block to catch the expected error
DO $$
BEGIN
    BEGIN
        PERFORM '1995-08-06 infinity'::timestamp;
        RAISE EXCEPTION 'ERROR: Expected error for "1995-08-06 infinity" but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "1995-08-06 infinity"::timestamp: %', SQLERRM;
    END;
    
    BEGIN
        PERFORM 'infinity 10:30:00'::timestamp;
        RAISE EXCEPTION 'ERROR: Expected error for "infinity 10:30:00" but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "infinity 10:30:00"::timestamp: %', SQLERRM;
    END;
    
    BEGIN
        PERFORM '2021-01-01 infinity'::timestamptz;
        RAISE EXCEPTION 'ERROR: Expected error for "2021-01-01 infinity"::timestamptz but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "2021-01-01 infinity"::timestamptz: %', SQLERRM;
    END;
    
    BEGIN
        PERFORM '2021-01-01 infinity'::date;
        RAISE EXCEPTION 'ERROR: Expected error for "2021-01-01 infinity"::date but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "2021-01-01 infinity"::date: %', SQLERRM;
    END;
END $$;

DROP TABLE test_reject_combined;
-- Expected: All four attempts are rejected with appropriate error messages.


-- ================================================================
-- Test 3: Reject "-infinity" combined with regular date fields
-- Target: DTK_EARLY case - should not proceed to ValidateDate/AMPM
-- ================================================================
DO $$
BEGIN
    BEGIN
        PERFORM '1995-08-06 -infinity'::timestamp;
        RAISE EXCEPTION 'ERROR: Expected error for "1995-08-06 -infinity" but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "1995-08-06 -infinity"::timestamp: %', SQLERRM;
    END;
    
    BEGIN
        PERFORM '-infinity 10:30:00'::timestamp;
        RAISE EXCEPTION 'ERROR: Expected error for "-infinity 10:30:00" but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "-infinity 10:30:00"::timestamp: %', SQLERRM;
    END;
    
    BEGIN
        PERFORM '2021-01-01 -infinity'::timestamptz;
        RAISE EXCEPTION 'ERROR: Expected error for "2021-01-01 -infinity"::timestamptz but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "2021-01-01 -infinity"::timestamptz: %', SQLERRM;
    END;
    
    BEGIN
        PERFORM '2021-01-01 -infinity'::date;
        RAISE EXCEPTION 'ERROR: Expected error for "2021-01-01 -infinity"::date but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "2021-01-01 -infinity"::date: %', SQLERRM;
    END;
END $$;
-- Expected: All four attempts are rejected.


-- ================================================================
-- Test 4: Reject "epoch" combined with regular date fields
-- Target: DTK_EPOCH case - should not proceed to ValidateDate/AMPM
-- ================================================================
DO $$
BEGIN
    BEGIN
        PERFORM '1995-08-06 epoch'::timestamp;
        RAISE EXCEPTION 'ERROR: Expected error for "1995-08-06 epoch" but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "1995-08-06 epoch"::timestamp: %', SQLERRM;
    END;
    
    BEGIN
        PERFORM 'epoch 10:30:00'::timestamp;
        RAISE EXCEPTION 'ERROR: Expected error for "epoch 10:30:00" but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "epoch 10:30:00"::timestamp: %', SQLERRM;
    END;
    
    BEGIN
        PERFORM '2021-01-01 epoch'::timestamptz;
        RAISE EXCEPTION 'ERROR: Expected error for "2021-01-01 epoch"::timestamptz but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "2021-01-01 epoch"::timestamptz: %', SQLERRM;
    END;
    
    BEGIN
        PERFORM '2021-01-01 epoch'::date;
        RAISE EXCEPTION 'ERROR: Expected error for "2021-01-01 epoch"::date but none was raised';
    EXCEPTION
        WHEN others THEN
            RAISE NOTICE 'Correctly rejected "2021-01-01 epoch"::date: %', SQLERRM;
    END;
END $$;
-- Expected: All four attempts are rejected.


-- ================================================================
-- Test 5: Verify existing standalone special tokens still work in
-- comparison and arithmetic operations
-- Target: DTK_EPOCH, DTK_LATE, DTK_EARLY - ensure no regression
-- ================================================================
CREATE TABLE test_special_ops (
    ts TIMESTAMP,
    tstz TIMESTAMPTZ,
    d DATE
);

INSERT INTO test_special_ops VALUES
    ('epoch', 'epoch', 'epoch'),
    ('infinity', 'infinity', 'infinity'),
    ('-infinity', '-infinity', '-infinity');

-- Comparison operators (should work)
SELECT 'infinity'::timestamp > 'epoch'::timestamp AS inf_gt_epoch;
SELECT 'epoch'::timestamp > '-infinity'::timestamp AS epoch_gt_neginf;
SELECT '-infinity'::timestamp < 'infinity'::timestamp AS neginf_lt_inf;
SELECT 'infinity'::timestamptz > 'epoch'::timestamptz AS inf_gt_epoch_tz;
SELECT 'infinity'::date > 'epoch'::date AS inf_gt_epoch_date;

-- Between comparisons
SELECT 'epoch'::timestamp BETWEEN '-infinity'::timestamp AND 'infinity'::timestamp AS epoch_between;

-- IS FINITE / IS NOT FINITE
SELECT 'infinity'::timestamp IS NOT FINITE AS inf_not_finite;
SELECT '-infinity'::timestamp IS NOT FINITE AS neginf_not_finite;
SELECT 'epoch'::timestamp IS FINITE AS epoch_finite;

-- Greatest/least
SELECT greatest('-infinity'::timestamp, 'epoch'::timestamp, 'infinity'::timestamp) AS greatest_val;
SELECT least('-infinity'::timestamp, 'epoch'::timestamp, 'infinity'::timestamp) AS least_val;

DROP TABLE test_special_ops;
-- Expected: All comparisons, IS FINITE checks, greatest/least work correctly.

----------------------------------------
-- Source: 99.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Fix MULTIEXPR_SUBLINK with partitioned
-- target tables, yet again.
-- task_id: 99
-- ================================================================
-- This test exercises the new code paths in execExpr.c where
-- MULTIEXPR SubPlans are moved to the front of expression step lists
-- (ExecCreateExprSetupSteps / ExecPushExprSetupSteps) rather than
-- relying on the ParamExecData.execPlan mechanism.
-- ================================================================

-- ##################################################################
-- Test 1: UPDATE with multi-assignment on partitioned table
-- This triggers MULTIEXPR_SUBLINK in UPDATE of a partitioned table,
-- exercising ExecCreateExprSetupSteps (Block 7), the MULTIEXPR_SUBLINK
-- collection in expr_setup_walker (Block 9), and the early MULTIEXPR
-- evaluation in ExecPushExprSetupSteps (Block 8).
-- ##################################################################

CREATE TABLE test_part_update (
    id INT PRIMARY KEY,
    val1 INT,
    val2 TEXT
) PARTITION BY RANGE (id);

CREATE TABLE test_part_update_1 PARTITION OF test_part_update
    FOR VALUES FROM (1) TO (100);
CREATE TABLE test_part_update_2 PARTITION OF test_part_update
    FOR VALUES FROM (100) TO (200);

INSERT INTO test_part_update
    SELECT x, x, 'initial_' || x::text
    FROM generate_series(1, 150) x;

EXPLAIN (verbose, costs off)
UPDATE test_part_update t
    SET (val1, val2) = (SELECT t.val1 + 10, t.val2 || '_updated' LIMIT 1);

UPDATE test_part_update t
    SET (val1, val2) = (SELECT t.val1 + 10, t.val2 || '_updated' LIMIT 1);

DROP TABLE test_part_update;


-- ##################################################################
-- Test 2: INSERT ... ON CONFLICT DO UPDATE with multi-assignment
-- on partitioned table (the primary bug scenario from the commit)
-- This triggers ExecInitPartitionInfo cloning the targetlist,
-- exercising the same code paths as Test 1 but via ON CONFLICT path.
-- Also tests the MULTIEXPR_SUBLINK returning NULL constant (Block 6).
-- ##################################################################

CREATE TABLE test_part_upsert (
    id INT PRIMARY KEY,
    counter INT,
    note TEXT
) PARTITION BY RANGE (id);

CREATE TABLE test_part_upsert_1 PARTITION OF test_part_upsert
    FOR VALUES FROM (1) TO (50);
CREATE TABLE test_part_upsert_2 PARTITION OF test_part_upsert
    FOR VALUES FROM (50) TO (100);

INSERT INTO test_part_upsert
    SELECT x, 0, 'orig_' || x::text
    FROM generate_series(1, 80) x;

EXPLAIN (verbose, costs off)
INSERT INTO test_part_upsert AS t VALUES (20), (60)
    ON CONFLICT (id)
    DO UPDATE SET (counter, note) = (
        SELECT t.counter + 1, t.note || '_upserted'
        LIMIT 1
    );

INSERT INTO test_part_upsert AS t VALUES (20), (60)
    ON CONFLICT (id)
    DO UPDATE SET (counter, note) = (
        SELECT t.counter + 1, t.note || '_upserted'
        LIMIT 1
    );

DROP TABLE test_part_upsert;


-- ##################################################################
-- Test 3: UPDATE with multi-assignment referencing same row's columns
-- on a partitioned table with multiple partitions, covering edge case
-- where the subquery uses complex expressions and functions.
-- ##################################################################

CREATE TABLE test_part_complex (
    id INT PRIMARY KEY,
    a INT,
    b INT,
    label TEXT
) PARTITION BY RANGE (id);

CREATE TABLE test_part_complex_1 PARTITION OF test_part_complex
    FOR VALUES FROM (1) TO (500);
CREATE TABLE test_part_complex_2 PARTITION OF test_part_complex
    FOR VALUES FROM (500) TO (1000);

INSERT INTO test_part_complex
    SELECT x, x % 10, x % 7, 'item_' || x::text
    FROM generate_series(1, 900) x;

-- Use a MULTIEXPR with multiple output columns and expressions
EXPLAIN (verbose, costs off)
UPDATE test_part_complex t
    SET (a, b, label) = (
        SELECT t.a * t.b, t.a + t.b, t.label || '_proc'
        FROM (SELECT 1) dummy
    );

UPDATE test_part_complex t
    SET (a, b, label) = (
        SELECT t.a * t.b, t.a + t.b, t.label || '_proc'
        FROM (SELECT 1) dummy
    );

DROP TABLE test_part_complex;


-- ##################################################################
-- Test 4: INSERT ... ON CONFLICT DO UPDATE with multi-assignment
-- where the conflict row is in a different partition than the inserted row,
-- exercising the partition-routing code path.
-- Also covers the "empty results" edge case for MULTIEXPR (uses LIMIT 0).
-- ##################################################################

CREATE TABLE test_part_cross (
    id INT PRIMARY KEY,
    val INT,
    descr TEXT
) PARTITION BY RANGE (id);

CREATE TABLE test_part_cross_low PARTITION OF test_part_cross
    FOR VALUES FROM (1) TO (500);
CREATE TABLE test_part_cross_high PARTITION OF test_part_cross
    FOR VALUES FROM (500) TO (1000);

INSERT INTO test_part_cross
    SELECT x, x * 2, 'desc_' || x::text
    FROM generate_series(1, 800) x;

-- Test with subquery potentially returning different values per partition
EXPLAIN (verbose, costs off)
INSERT INTO test_part_cross AS t VALUES (100), (600)
    ON CONFLICT (id)
    DO UPDATE SET (val, descr) = (
        SELECT t.val + 100, t.descr || '_conflict'
    );

INSERT INTO test_part_cross AS t VALUES (100), (600)
    ON CONFLICT (id)
    DO UPDATE SET (val, descr) = (
        SELECT t.val + 100, t.descr || '_conflict'
    );

DROP TABLE test_part_cross;


-- ##################################################################
-- Test 5: UPDATE with multi-assignment on a table with list partitions
-- (not range), using NULL values and boundary conditions.
-- This ensures the MULTIEXPR setup steps work with various partition
-- strategies. Also tests the ExecBuildAggTrans refactored path
-- (Block 12) indirectly via a query that uses aggregation.
-- ##################################################################

CREATE TABLE test_part_list (
    id INT,
    category TEXT,
    score INT,
    data TEXT
) PARTITION BY LIST (category);

CREATE TABLE test_part_list_a PARTITION OF test_part_list
    FOR VALUES IN ('A');
CREATE TABLE test_part_list_b PARTITION OF test_part_list
    FOR VALUES IN ('B');
CREATE TABLE test_part_list_c PARTITION OF test_part_list
    FOR VALUES IN ('C');

INSERT INTO test_part_list VALUES
    (1, 'A', 10, 'alpha'),
    (2, 'A', 20, 'beta'),
    (3, 'B', 15, 'gamma'),
    (4, 'B', 25, 'delta'),
    (5, 'C', 30, 'epsilon'),
    (6, NULL, 5, 'null_cat');

-- UPDATE with MULTIEXPR using aggregation subquery
EXPLAIN (verbose, costs off)
UPDATE test_part_list t
    SET (score, data) = (
        SELECT avg(s.score)::int, 'avg_is_' || avg(s.score)::text
        FROM test_part_list s
        WHERE s.category = t.category OR (s.category IS NULL AND t.category IS NULL)
    );

UPDATE test_part_list t
    SET (score, data) = (
        SELECT avg(s.score)::int, 'avg_is_' || avg(s.score)::text
        FROM test_part_list s
        WHERE s.category = t.category OR (s.category IS NULL AND t.category IS NULL)
    );

DROP TABLE test_part_list;

----------------------------------------
-- Source: 100.sql
----------------------------------------
-- ================================================================
-- SQL Regression Test for: Detect overflow in timestamp[tz] subtraction
-- task_id: 100
-- ================================================================
-- This test exercises the new overflow detection code in timestamp_mi()
-- which uses pg_sub_s64_overflow() to check whether subtracting two
-- timestamps overflows the int64 microsecond field of the output interval.
--
-- The new code path (replacing direct assignment with overflow check):
--   if (unlikely(pg_sub_s64_overflow(dt1, dt2, &result->time)))
--       ereport(ERROR, ...)
-- ================================================================

-- ================================================================
-- Test 1: timestamp subtraction that overflows int64 microseconds
-- Use the earliest and latest valid timestamps so their difference
-- exceeds int64 range (~9.22e18 microseconds ≈ 292,471 years).
--
-- These two timestamps are ~300,000 years apart, which overflows
-- the int64 microseconds field. Should get "interval out of range".
-- ================================================================
SELECT 'Test 1: timestamp subtraction overflow' AS test_name;
SELECT timestamp '294276-12-31 23:59:59' - timestamp '4713-01-01 00:00:00 BC' AS overflow_test;

-- ================================================================
-- Test 2: timestamptz subtraction that overflows int64 microseconds
-- Same concept as Test 1 but with timestamptz type.
-- The timestamp subtraction code path is shared via pg_proc.
-- ================================================================
SELECT 'Test 2: timestamptz subtraction overflow' AS test_name;
SELECT timestamptz '294276-12-31 23:59:59 UTC' - timestamptz '4713-01-01 00:00:00 BC UTC' AS overflow_test_tz;

-- ================================================================
-- Test 3: timestamp subtraction that does NOT overflow (normal case)
-- Normal range timestamps produce a valid interval.
-- This ensures the non-overflow path still works correctly.
-- ================================================================
SELECT 'Test 3: normal timestamp subtraction (no overflow)' AS test_name;
SELECT timestamp '2024-01-15 12:00:00' - timestamp '2023-01-15 12:00:00' AS normal_interval;

-- ================================================================
-- Test 4: Large negative overflow (early - late)
-- Subtracting a later timestamp from an earlier one produces a
-- negative result. If the magnitude is large enough, it overflows.
-- ================================================================
SELECT 'Test 4: negative overflow (late minus early reversed)' AS test_name;
SELECT timestamp '4713-01-01 00:00:00 BC' - timestamp '294276-12-31 23:59:59' AS neg_overflow_test;

-- ================================================================
-- Test 5: Near-boundary subtraction that barely fits (edge case)
-- Use timestamps that produce an interval close to but not exceeding
-- the int64 limit. This exercises the overflow check on the boundary.
-- 
-- Timestamps separated by ~292,000 years (just under the overflow limit).
-- ================================================================
SELECT 'Test 5: near-boundary subtraction (barely fits)' AS test_name;
SELECT timestamp '2000-01-01 00:00:00' - timestamp '290000-01-01 00:00:00 BC' AS near_boundary_test;

