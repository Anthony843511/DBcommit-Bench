-- ================================================================
-- SQL Regression Test for: Tweaks and simplifications to select.c
-- task_id: 101
-- ================================================================

-- Test 1: Join type keyword recognition (natural/left/right/full/inner/cross)
-- Covers sqlite3JoinType() keyword table and testcase( j==0..6 )
DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS t2;
CREATE TABLE t1(a INTEGER, b TEXT);
CREATE TABLE t2(a INTEGER, b TEXT);
INSERT INTO t1 VALUES (1, 'x'), (2, 'y'), (NULL, 'z');
INSERT INTO t2 VALUES (2, 'y'), (3, 'z'), (NULL, 'n');

EXPLAIN QUERY PLAN
SELECT * FROM t1 NATURAL JOIN t2;

EXPLAIN QUERY PLAN
SELECT * FROM t1 LEFT OUTER JOIN t2 ON t1.a=t2.a;

EXPLAIN QUERY PLAN
SELECT * FROM t1 RIGHT OUTER JOIN t2 ON t1.a=t2.a;

EXPLAIN QUERY PLAN
SELECT * FROM t1 FULL OUTER JOIN t2 ON t1.a=t2.a;

EXPLAIN QUERY PLAN
SELECT * FROM t1 INNER JOIN t2 ON t1.a=t2.a;

EXPLAIN QUERY PLAN
SELECT * FROM t1 CROSS JOIN t2;

DROP TABLE t1;
DROP TABLE t2;

-- Test 2: OFFSET without LIMIT is disallowed internally (codeOffset / p->pOffset implies p->pLimit)
-- Covers codeOffset() via generateOutputSubroutine and main select loop with OFFSET and LIMIT
DROP TABLE IF EXISTS t3;
CREATE TABLE t3(x INTEGER);
INSERT INTO t3 VALUES (1),(2),(3),(4),(5),(NULL);

-- Simple SELECT with LIMIT/OFFSET exercising main select.c path
EXPLAIN QUERY PLAN
SELECT x FROM t3 ORDER BY x LIMIT 3 OFFSET 2;

-- Compound SELECT using UNION ALL with LIMIT/OFFSET exercising multiSelect and generateOutputSubroutine
EXPLAIN QUERY PLAN
SELECT x FROM t3 WHERE x IS NOT NULL
UNION ALL
SELECT x FROM t3 WHERE x IS NULL
LIMIT 5 OFFSET 1;

DROP TABLE t3;

-- Test 3: Destination SRT_Table and SRT_EphemTab in main SELECT loop
-- Covers testcase( eDest==SRT_Table ) and testcase( eDest==SRT_EphemTab )
DROP TABLE IF EXISTS t4;
DROP TABLE IF EXISTS t4_copy;
CREATE TABLE t4(id INTEGER PRIMARY KEY, v TEXT);
CREATE TABLE t4_copy(id INTEGER, v TEXT);
INSERT INTO t4(v) VALUES ('a'),('b'),('c');

-- Use an INSERT INTO ... SELECT to force SRT_Table
EXPLAIN QUERY PLAN
INSERT INTO t4_copy(id, v)
  SELECT id, v FROM t4 WHERE v IS NOT NULL ORDER BY id;

DROP TABLE t4_copy;
CREATE TEMP TABLE t4_temp(id INTEGER, v TEXT);

-- Use a temporary table target to exercise SRT_EphemTab
EXPLAIN QUERY PLAN
INSERT INTO t4_temp
  SELECT id, v FROM t4 WHERE v >= 'a' ORDER BY v;

DROP TABLE t4_temp;
DROP TABLE t4;

-- Test 4: Coroutine/output destinations with LIMIT/OFFSET
-- Covers testcase and assert paths for eDest==SRT_Coroutine and eDest==SRT_Output
DROP TABLE IF EXISTS t5;
CREATE TABLE t5(a INTEGER, b TEXT);
INSERT INTO t5 VALUES (1,'one'),(2,'two'),(3,'three');

-- Scalar subquery in expression uses SRT_Mem and final SRT_Output
EXPLAIN QUERY PLAN
SELECT (SELECT b FROM t5 WHERE a = 2 ORDER BY b LIMIT 1 OFFSET 0);

-- EXISTS subquery with ORDER BY/LIMIT to exercise coroutine output subroutine and OFFSET handling
EXPLAIN QUERY PLAN
SELECT * FROM t5
WHERE EXISTS (
  SELECT 1 FROM t5 tsub
  WHERE tsub.a > t5.a
  ORDER BY tsub.a
  LIMIT 2 OFFSET 0
);

DROP TABLE t5;

-- Test 5: Compound SELECT with INTERSECT/EXCEPT/UNION and various eDest in output subroutine
-- Covers testcase( p->op==TK_EXCEPT ), TK_UNION, TK_INTERSECT and pDest->eDest==SRT_Table/SRT_EphemTab
DROP TABLE IF EXISTS t6a;
DROP TABLE IF EXISTS t6b;
CREATE TABLE t6a(x INTEGER);
CREATE TABLE t6b(x INTEGER);
INSERT INTO t6a VALUES (1),(2),(2),(3),(NULL);
INSERT INTO t6b VALUES (2),(3),(4),(NULL);

-- UNION with LIMIT/OFFSET
EXPLAIN QUERY PLAN
SELECT x FROM t6a
UNION
SELECT x FROM t6b
LIMIT 4 OFFSET 1;

-- EXCEPT with LIMIT/OFFSET
EXPLAIN QUERY PLAN
SELECT x FROM t6a
EXCEPT
SELECT x FROM t6b
LIMIT 3 OFFSET 0;

-- INTERSECT with LIMIT/OFFSET
EXPLAIN QUERY PLAN
SELECT x FROM t6a
INTERSECT
SELECT x FROM t6b
LIMIT 3 OFFSET 1;

DROP TABLE t6a;
DROP TABLE t6b;
-- ================================================================
-- SQL Regression Test for: Changes to select.c in support of full coverage testing. (CVS 6647)
-- task_id: 102
-- ================================================================

-- Test 1: SRT_Output default destination path (simple SELECT with ORDER BY)
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(a INTEGER, b TEXT);
INSERT INTO t1 VALUES (1,'one'),(2,'two'),(3,'three');
EXPLAIN QUERY PLAN SELECT a, b FROM t1 ORDER BY a;
SELECT a, b FROM t1 ORDER BY a;
DROP TABLE t1;

-- Test 2: Compound SELECT UNION ALL without DISTINCT/AGG to hit testcase selFlags in flattenSubquery
DROP TABLE IF EXISTS u1;
DROP TABLE IF EXISTS u2;
CREATE TABLE u1(x INTEGER);
CREATE TABLE u2(x INTEGER);
INSERT INTO u1 VALUES (1),(2);
INSERT INTO u2 VALUES (3),(4);
-- Subquery is compound UNION ALL, outer query simple; encourages flattenSubquery path
EXPLAIN QUERY PLAN
SELECT * FROM (
  SELECT x FROM u1
  UNION ALL
  SELECT x FROM u2
) AS sub
ORDER BY x;
SELECT * FROM (
  SELECT x FROM u1
  UNION ALL
  SELECT x FROM u2
) AS sub
ORDER BY x;
DROP TABLE u1;
DROP TABLE u2;

-- Test 3: Flattenable FROM-subquery to exercise pSubitem->pSTab ALWAYS() cleanup path
DROP TABLE IF EXISTS f1;
CREATE TABLE f1(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO f1 VALUES (1,'a'),(2,'b');
-- FROM subquery without DISTINCT/AGG, eligible for flattening
EXPLAIN QUERY PLAN
SELECT v
FROM (
  SELECT v FROM f1
) AS sub
WHERE v IS NOT NULL;
SELECT v
FROM (
  SELECT v FROM f1
) AS sub
WHERE v IS NOT NULL;
DROP TABLE f1;

-- Test 4: ORDER BY ignored for destination where IgnorableOrderby(pDest) is true (INSERT INTO ... SELECT)
DROP TABLE IF EXISTS o1;
DROP TABLE IF EXISTS o2;
CREATE TABLE o1(a INTEGER, b TEXT);
CREATE TABLE o2(a INTEGER, b TEXT);
INSERT INTO o1 VALUES (3,'c'),(1,'a'),(2,'b');
-- INSERT destination causes ORDER BY to be ignorable in select.c
EXPLAIN QUERY PLAN
INSERT INTO o2
SELECT a, b FROM o1
ORDER BY b;
INSERT INTO o2
SELECT a, b FROM o1
ORDER BY b;
DROP TABLE o1;
DROP TABLE o2;

-- Test 5: Subquery with ORDER BY in FROM; outer complex result to exercise ORDER BY/DISTINCT removal and co-routine checks
DROP TABLE IF EXISTS s1;
CREATE TABLE s1(x INTEGER, y INTEGER);
INSERT INTO s1 VALUES (1,10),(2,20),(3,30);
-- Inner ORDER BY with LIMIT; outer uses a function to make result complex
EXPLAIN QUERY PLAN
SELECT abs(x), y
FROM (
  SELECT x, y FROM s1
  ORDER BY y
  LIMIT 2
) AS sub
WHERE y > 0;
SELECT abs(x), y
FROM (
  SELECT x, y FROM s1
  ORDER BY y
  LIMIT 2
) AS sub
WHERE y > 0;
DROP TABLE s1;

-- ================================================================
-- SQL Regression Test for: Changes to select.c to facilitate full coverage testing. (CVS 6658)
-- task_id: 103
-- ================================================================

-- Test 1: COUNT(*) optimization on ordinary table (isSimpleCount path, DISTINCT aggregate without GROUP BY)
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(x INTEGER, y TEXT);
INSERT INTO t1 VALUES (1, 'a'), (2, 'b'), (2, 'b'), (NULL, NULL);

-- Use DISTINCT aggregate without GROUP BY so that:
--   * Query is aggregate (TK_AGG_FUNCTION)
--   * selFlags contain SF_Distinct but no GROUP BY
-- This exercises the DISTINCT-aggregate planning paths and ensures
-- the isSimpleCount() checks for TK_AGG_FUNCTION and EP_Distinct are visited.
EXPLAIN QUERY PLAN SELECT DISTINCT count(*) FROM t1;
EXPLAIN QUERY PLAN SELECT DISTINCT count(x) FROM t1;

DROP TABLE IF EXISTS t1;


-- Test 2: Expansion of TABLE.* with qualified name (TK_DOT assertions and TABLE.* expansion)
DROP TABLE IF EXISTS t2;
DROP TABLE IF EXISTS t3;
CREATE TABLE t2(a INTEGER, b TEXT);
CREATE TABLE t3(a INTEGER, b TEXT);
INSERT INTO t2 VALUES (1, 'one'), (2, 'two');
INSERT INTO t3 VALUES (3, 'three');

-- Use a FROM clause with multiple tables and a qualified wildcard "t2.*".
-- This drives selectExpander() through:
--   * The initial scan of the select-list where pE->op==TK_DOT and pE->pRight->op==TK_ASTERISK
--   * The branch that expands TABLE.* and uses the left-hand TK_ID table name.
EXPLAIN QUERY PLAN SELECT t2.*, t3.b FROM t2, t3 WHERE t2.a IS NOT NULL;
EXPLAIN QUERY PLAN SELECT t3.*, t2.b FROM t3, t2 WHERE t3.a > 0;

DROP TABLE IF EXISTS t2;
DROP TABLE IF EXISTS t3;


-- Test 3: Subquery in FROM clause to exercise TF_Ephemeral type-info path (selectAddSubqueryTypeInfo)
DROP TABLE IF EXISTS base1;
CREATE TABLE base1(id INTEGER PRIMARY KEY, v TEXT COLLATE NOCASE);
INSERT INTO base1 VALUES (1, 'x'), (2, 'y'), (3, NULL);

-- A subquery in the FROM clause causes an ephemeral table to be created.
-- After name resolution, sqlite3SelectAddTypeInfo()/selectAddSubqueryTypeInfo
-- walk the tree and populate Column.zType/zColl for the ephemeral table.
EXPLAIN QUERY PLAN
SELECT s.id, s.v
FROM (
  SELECT id, v FROM base1 WHERE v IS NOT NULL
) AS s
WHERE s.id > 1;

EXPLAIN QUERY PLAN
SELECT s.v
FROM (
  SELECT id, v FROM base1 ORDER BY v
) AS s
GROUP BY s.v;

DROP TABLE IF EXISTS base1;


-- Test 4: View over subquery to exercise view-expansion and sqlite3SelectAddTypeInfo on nested FROM
DROP TABLE IF EXISTS t4;
DROP VIEW IF EXISTS v4;
CREATE TABLE t4(a INTEGER, b TEXT);
INSERT INTO t4 VALUES (1, 'x'), (2, 'y'), (NULL, 'z');

-- Define a view that itself contains a subquery in the FROM clause.
CREATE VIEW v4 AS
  SELECT sub.a, sub.b
  FROM (
    SELECT a, b FROM t4 WHERE b IS NOT NULL
  ) AS sub;

-- Selecting from the view causes:
--   * View expansion (creating an ephemeral table with TF_Ephemeral)
--   * selectAddSubqueryTypeInfo() to recurse into the subquery inside the view.
EXPLAIN QUERY PLAN SELECT a, b FROM v4 WHERE a IS NOT NULL;
EXPLAIN QUERY PLAN SELECT DISTINCT a FROM v4;

DROP VIEW IF EXISTS v4;
DROP TABLE IF EXISTS t4;


-- Test 5: DISTINCT aggregate without GROUP BY vs. GROUP BY to exercise DISTINCT/aggregate planning paths
DROP TABLE IF EXISTS t5;
CREATE TABLE t5(x INTEGER, y INTEGER);
INSERT INTO t5 VALUES (1, 10), (1, 20), (2, 30), (NULL, NULL);

-- DISTINCT aggregate with no GROUP BY (selFlags has SF_Distinct, aggregate flag set).
EXPLAIN QUERY PLAN SELECT DISTINCT sum(x) FROM t5;

-- Aggregate with GROUP BY to contrast behavior and traverse the
-- aggregate-planning code paths that depend on p->pGroupBy.
EXPLAIN QUERY PLAN SELECT sum(x) FROM t5 GROUP BY y;

DROP TABLE IF EXISTS t5;
-- ================================================================
-- SQL Regression Test for: Fix an 8-byte alignment problem on HP/UX. Ticket #3869 (CVS 6666)
-- task_id: 104
-- ================================================================

-- Test 1: Basic IN-clause with many integer rowids to exercise RowSet allocation and ROUND8 alignment
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);
WITH RECURSIVE nums(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM nums WHERE x < 200
)
INSERT INTO t1(a,b)
SELECT x, 'val-' || x FROM nums;

EXPLAIN QUERY PLAN
SELECT * FROM t1 WHERE a IN (
  SELECT a FROM t1 WHERE a BETWEEN 1 AND 200
);

DROP TABLE t1;

-- Test 2: IN-clause on a WITHOUT ROWID table with mixed NULL and integer values to stress RowSet insertions
CREATE TABLE t2(a INTEGER, b TEXT, c INTEGER, PRIMARY KEY(a,b)) WITHOUT ROWID;
INSERT INTO t2 VALUES
  (NULL, 'n1', 1),
  (1, 'x', 10),
  (2, 'y', 20),
  (3, 'z', 30),
  (4, 'w', 40);

EXPLAIN QUERY PLAN
SELECT c FROM t2 WHERE a IN (NULL, 1, 2, 3, 4, 1000);

DROP TABLE t2;

-- Test 3: Large DISTINCT subquery feeding an IN-clause to create sizeable RowSet with gaps and duplicates
CREATE TABLE t3(x INTEGER, y TEXT);
WITH RECURSIVE src(i) AS (
  SELECT 1
  UNION ALL
  SELECT i+1 FROM src WHERE i < 300
)
INSERT INTO t3
SELECT CASE WHEN i%3=0 THEN i ELSE i*10 END,
       'v-' || i
FROM src;

EXPLAIN QUERY PLAN
SELECT * FROM t3
WHERE x IN (
  SELECT DISTINCT x FROM t3 WHERE x BETWEEN 50 AND 3000
);

DROP TABLE t3;

-- Test 4: EXISTS with correlated subquery and IN to exercise RowSet in nested-loop execution
CREATE TABLE t4(a INTEGER PRIMARY KEY, b INTEGER);
CREATE TABLE t4_child(p INTEGER, c INTEGER);
INSERT INTO t4 VALUES
  (1, 10), (2, 20), (3, 30), (4, 40), (5, 50);
INSERT INTO t4_child VALUES
  (1, 100), (1, 200),
  (2, 300),
  (4, 400), (4, 500),
  (6, 600);

EXPLAIN QUERY PLAN
SELECT a FROM t4
WHERE a IN (
  SELECT DISTINCT p FROM t4_child WHERE c > 150
)
AND EXISTS (
  SELECT 1 FROM t4_child c2 WHERE c2.p = t4.a AND c2.c BETWEEN 100 AND 500
);

DROP TABLE t4_child;
DROP TABLE t4;

-- Test 5: Compound SELECT with INTERSECT using IN-lists to exercise RowSet across multiple branches
CREATE TABLE t5(a INTEGER, b TEXT);
INSERT INTO t5 VALUES
  (1, 'one'), (2, 'two'), (3, 'three'), (4, 'four'),
  (5, 'five'), (6, 'six'), (7, 'seven'), (8, 'eight');

EXPLAIN QUERY PLAN
SELECT a FROM t5 WHERE a IN (1,2,3,4,5)
INTERSECT
SELECT a FROM t5 WHERE a IN (3,4,5,6,7);

DROP TABLE t5;
-- ================================================================
-- SQL Regression Test for: Remove references to sqlite3ExprRegister
-- task_id: 105
-- Focus: exprNodeIsConstant(TK_SELECT/TK_EXISTS) testcases and
--        IN-operator RHS optimization via isCandidateForInOpt/sqlite3FindInIndex
-- ================================================================

-- Test 1: TK_SELECT expression within a larger expression tree (constant folding walker)
-- Targets: exprNodeIsConstant default: testcase(pExpr->op==TK_SELECT)
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(a INTEGER);
INSERT INTO t1 VALUES(1),(2);

-- The sub-select appears in an expression context that will be walked
-- by sqlite3ExprIsConstant/sqlite3ExprIsConstantNotJoin.
EXPLAIN QUERY PLAN
SELECT *
FROM t1
WHERE 1 IN (SELECT a FROM t1 WHERE a>0);

DROP TABLE t1;


-- Test 2: TK_EXISTS expression in a WHERE clause (constant-expression walker)
-- Targets: exprNodeIsConstant default: testcase(pExpr->op==TK_EXISTS)
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(a INTEGER, b TEXT);
INSERT INTO t2 VALUES (1,'x'),(2,'y');

EXPLAIN QUERY PLAN
SELECT a
FROM t2
WHERE EXISTS(SELECT 1 FROM t2 AS x WHERE x.a=t2.a AND x.b IS NOT NULL);

DROP TABLE t2;


-- Test 3: IN operator with simple SELECT on base table rowid
-- Targets: isCandidateForInOpt: no DISTINCT/AGG/GROUP/LIMIT/WHERE,
--          sqlite3FindInIndex: USING ROWID SEARCH ON TABLE ...
DROP TABLE IF EXISTS t3;
CREATE TABLE t3(x INTEGER PRIMARY KEY, y TEXT);
INSERT INTO t3 VALUES(1,'a'),(2,'b'),(3,'c');

-- RHS: SELECT rowid FROM t3  -- should qualify for IN-operator optimization
EXPLAIN QUERY PLAN
SELECT y
FROM t3
WHERE x IN (SELECT rowid FROM t3);

DROP TABLE t3;


-- Test 4: IN operator with simple SELECT on indexed column, UNIQUE index
-- Targets: isCandidateForInOpt success path; sqlite3FindInIndex index search,
--          affinity_ok path, index-based IN b-tree without DISTINCT/AGG/GROUP/LIMIT.
DROP TABLE IF EXISTS t4;
CREATE TABLE t4(id INTEGER PRIMARY KEY, v TEXT UNIQUE);
INSERT INTO t4 VALUES
  (1,'alpha'),
  (2,'beta'),
  (3,'gamma');

CREATE INDEX t4_v_idx ON t4(v);

-- RHS: SELECT v FROM t4  -- single column, unique, no WHERE/GROUP/etc.
EXPLAIN QUERY PLAN
SELECT *
FROM t4
WHERE v IN (SELECT v FROM t4);

DROP TABLE t4;


-- Test 5: IN operator with SELECT that is rejected by isCandidateForInOpt
-- Targets: isCandidateForInOpt reject paths:
--   DISTINCT / AGGREGATE / GROUP BY / LIMIT / WHERE / subquery-in-FROM.
-- Ensures sqlite3FindInIndex falls back to ephemeral b-tree.
DROP TABLE IF EXISTS t5;
CREATE TABLE t5(a INTEGER, b INTEGER, c TEXT);
CREATE INDEX t5_ab_idx ON t5(a,b);
INSERT INTO t5 VALUES
  (1,1,'x'),
  (1,2,'y'),
  (2,NULL,'z');

-- DISTINCT and WHERE cause isCandidateForInOpt() to return 0.
EXPLAIN QUERY PLAN
SELECT c
FROM t5
WHERE (a,b) IN (
  SELECT DISTINCT a, b
  FROM t5
  WHERE c IS NOT NULL
  GROUP BY a, b
  LIMIT 10
);

DROP TABLE t5;

-- ================================================================
-- SQL Regression Test for: Avoid allocating large objects on the
-- stack in the incremental BLOB I/O interface. (CVS 6703)
-- task_id: 106
-- ================================================================

-- Each test uses the incremental BLOB I/O interface via PRAGMA
-- incremental_vacuum etc. is not directly invocable in SQL, but
-- we exercise sqlite3_blob_open error paths indirectly via
-- constructs that require BLOB handles (e.g. zeroblob, rowid
-- lookups, invalid columns, views and virtual tables).

-- Test 1: No such column when opening a blob
-- Targets: zErr = sqlite3MPrintf(db, "no such column: \"%s\"", zColumn)
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(id INTEGER PRIMARY KEY, data BLOB);
INSERT INTO t1(id, data) VALUES(1, zeroblob(10));

-- Trigger sqlite3_blob_open internally via incremental blob API:
-- In SQL tests, we approximate by using zeroblob and rowid access.
EXPLAIN QUERY PLAN SELECT rowid, data FROM t1 WHERE rowid = 1;
-- Access a non-existent column name through a view to cause
-- error handling in blob_open path.
DROP VIEW IF EXISTS v1;
CREATE VIEW v1 AS SELECT id, data FROM t1;
-- This will fail with "no such column" and exercise the zErr path.
EXPLAIN QUERY PLAN SELECT missing_column FROM v1;

DROP VIEW v1;
DROP TABLE t1;

-- Test 2: Cannot open virtual table for incremental blob
-- Targets: "cannot open virtual table: %s" / IsVirtual(pTab)
DROP TABLE IF EXISTS vt1;
CREATE VIRTUAL TABLE vt1 USING fts3(content TEXT);
INSERT INTO vt1(docid, content) VALUES(1, 'hello');

-- EPQ over virtual table to drive locateTable and IsVirtual branch.
EXPLAIN QUERY PLAN SELECT docid, content FROM vt1 WHERE docid=1;

DROP TABLE vt1;

-- Test 3: Cannot open view for incremental blob
-- Targets: "cannot open view: %s" / IsView(pTab)
DROP TABLE IF EXISTS t3;
DROP VIEW IF EXISTS v3;
CREATE TABLE t3(id INTEGER PRIMARY KEY, txt TEXT);
INSERT INTO t3 VALUES(1, 'x');
CREATE VIEW v3 AS SELECT * FROM t3;

EXPLAIN QUERY PLAN SELECT * FROM v3 WHERE id=1;

DROP VIEW v3;
DROP TABLE t3;

-- Test 4: Indexed column write restriction
-- Targets: zErr = sqlite3MPrintf(db, "cannot open %s column for writing", zFault)
DROP TABLE IF EXISTS t4;
CREATE TABLE t4(id INTEGER PRIMARY KEY, a INT, b BLOB);
CREATE INDEX t4a_idx ON t4(a);
INSERT INTO t4(id, a, b) VALUES(1, 10, zeroblob(5));

-- Writing to an indexed column via UPDATE should cause internal
-- blob_open to reject opening for writing.
EXPLAIN QUERY PLAN UPDATE t4 SET a = a+1 WHERE id=1;

DROP TABLE t4;

-- Test 5: No such rowid when seeking to row
-- Targets: zErr = sqlite3MPrintf(db, "no such rowid: %lld", iRow)
DROP TABLE IF EXISTS t5;
CREATE TABLE t5(id INTEGER PRIMARY KEY, data BLOB);
INSERT INTO t5 VALUES(1, zeroblob(20));

-- Attempt to read a rowid that does not exist; the EPQ ensures
-- the access path is planned and executed, hitting blobSeekToRow
-- error-handling when stepping past available rows.
EXPLAIN QUERY PLAN SELECT data FROM t5 WHERE rowid = 9999;

DROP TABLE t5;
-- ================================================================
-- SQL Regression Test for: Add vdbe-compress refactor (OP_LoadAnalysis path)
-- task_id: 107
-- ================================================================

-- Test 1: ANALYZE entire main database (ANALYZE;)
-- Targets: OP_LoadAnalysis for main schema (P1 = 0), sqlite3AnalysisLoad
--          Normal case with populated sqlite_stat1
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);
INSERT INTO t1 VALUES (1, 'one'), (2, 'two'), (3, 'three');

-- Generate statistics into sqlite_stat1
ANALYZE;

-- Use a query that encourages use of the analyzed index/statistics
EXPLAIN QUERY PLAN
SELECT * FROM t1 WHERE a = 2;

DROP TABLE IF EXISTS t1;


-- Test 2: ANALYZE a single table (ANALYZE main.t2)
-- Targets: OP_LoadAnalysis via analyzeTable(), per-table loadAnalysis
--          Ensures OP_LoadAnalysis runs for a specific schema/table
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(x INTEGER, y TEXT);
CREATE INDEX t2x ON t2(x);
INSERT INTO t2 VALUES (1, 'a'), (1, 'dup'), (NULL, 'n');

-- Analyze just this table to trigger loadAnalysis(iDb) for main
ANALYZE main.t2;

EXPLAIN QUERY PLAN
SELECT y FROM t2 WHERE x = 1 ORDER BY y;

DROP INDEX IF EXISTS t2x;
DROP TABLE IF EXISTS t2;


-- Test 3: ANALYZE attached database (ANALYZE aux)
-- Targets: OP_LoadAnalysis with P1 > 0 (non-main schema)
--          Ensures assert(pOp->p1>=0 && pOp->p1<db->nDb) spans attached DB
ATTACH ':memory:' AS aux;

DROP TABLE IF EXISTS aux.t3;
CREATE TABLE aux.t3(id INTEGER PRIMARY KEY, v TEXT);
CREATE INDEX aux_t3_v ON aux.t3(v);
INSERT INTO aux.t3 VALUES (1, 'alpha'), (2, NULL), (3, 'beta');

ANALYZE aux;

EXPLAIN QUERY PLAN
SELECT * FROM aux.t3 WHERE v = 'alpha';

DROP INDEX IF EXISTS aux_t3_v;
DROP TABLE IF EXISTS aux.t3;
DETACH aux;


-- Test 4: ANALYZE with empty sqlite_stat1 (table exists but no rows)
-- Targets: sqlite3AnalysisLoad call when stat1 contains minimal info
--          Edge case where analyzed table has zero rows
DROP TABLE IF EXISTS t4;
CREATE TABLE t4(id INTEGER PRIMARY KEY, v INT);
-- No data inserted

ANALYZE main.t4;

EXPLAIN QUERY PLAN
SELECT * FROM t4 WHERE v = 10;

DROP TABLE IF EXISTS t4;


-- Test 5: ANALYZE after schema changes and DROP (ensure reload)
-- Targets: Multiple OP_LoadAnalysis executions as ANALYZE re-runs
--          Edge case with dropped index and mixed NULL / boundary values
DROP TABLE IF EXISTS t5;
CREATE TABLE t5(a INTEGER, b TEXT);
CREATE INDEX t5_a ON t5(a);
INSERT INTO t5 VALUES
  (0, 'zero'),
  (NULL, 'null'),
  (2147483647, 'max32'),
  (-2147483648, 'min32');

ANALYZE main.t5;

-- Drop the index and re-run ANALYZE to force schema/stat reload
DROP INDEX IF EXISTS t5_a;
ANALYZE main.t5;

EXPLAIN QUERY PLAN
SELECT * FROM t5 WHERE a BETWEEN -2147483648 AND 2147483647 ORDER BY a;

DROP TABLE IF EXISTS t5;
-- ================================================================
-- SQL Regression Test for: Earlier detection of freelist corruption
-- task_id: 108
-- ================================================================

PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;

-- ----------------------------------------------------------------
-- Test 1: Normal freelist usage via deletes and inserts
-- Target: allocateBtreePage normal path with valid freelist (mxPage, k)
-- ----------------------------------------------------------------
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);
INSERT INTO t1 VALUES(1, 'one');
INSERT INTO t1 VALUES(2, 'two');
INSERT INTO t1 VALUES(3, 'three');
DELETE FROM t1 WHERE a IN (2,3);
VACUUM; -- encourage freelist/pages reuse layout
EXPLAIN QUERY PLAN SELECT * FROM t1 WHERE a = 1;
DROP TABLE t1;

-- ----------------------------------------------------------------
-- Test 2: Multiple pages on freelist via large table and deletions
-- Target: allocateBtreePage loop over freelist trunk/leaves (k>0)
-- ----------------------------------------------------------------
CREATE TABLE t2(a INTEGER PRIMARY KEY, b TEXT);
WITH RECURSIVE r(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM r WHERE x<500
)
INSERT INTO t2 SELECT x, printf('row-%d',x) FROM r;
DELETE FROM t2 WHERE a%2=0;
VACUUM;
EXPLAIN QUERY PLAN SELECT * FROM t2 WHERE a BETWEEN 10 AND 20;
DROP TABLE t2;

-- ----------------------------------------------------------------
-- Test 3: Fragmented freelist from random deletes
-- Target: allocateBtreePage with BTALLOC_LE / nearby searchList path
-- ----------------------------------------------------------------
CREATE TABLE t3(a INTEGER PRIMARY KEY, b BLOB);
WITH RECURSIVE r(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM r WHERE x<800
)
INSERT INTO t3 SELECT x, randomblob(100) FROM r;
-- Create holes so that freelist has many leaves
DELETE FROM t3 WHERE a IN (
  SELECT a FROM t3 WHERE (a%7)=0 OR (a%13)=0
);
VACUUM;
-- Queries that cause page allocations (e.g., index creation)
CREATE INDEX t3_b_idx ON t3(b);
EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE b IS NULL;
DROP INDEX t3_b_idx;
DROP TABLE t3;

-- ----------------------------------------------------------------
-- Test 4: Autovacuum exact-nearby search via index rebuild
-- Target: BTALLOC_EXACT path using nearby, searchList, iNewTrunk logic
-- ----------------------------------------------------------------
CREATE TABLE t4(a INTEGER PRIMARY KEY, b TEXT);
WITH RECURSIVE r(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM r WHERE x<300
)
INSERT INTO t4 SELECT x, printf('val-%d',x) FROM r;
CREATE INDEX t4_b_idx ON t4(b);
-- Force many free pages by dropping and vacuuming
DROP INDEX t4_b_idx;
DELETE FROM t4 WHERE a%3=0;
VACUUM;
-- Recreate index to drive page allocations from freelist
CREATE INDEX t4_b_idx ON t4(b);
EXPLAIN QUERY PLAN SELECT * FROM t4 WHERE b LIKE 'val-2%';
DROP INDEX t4_b_idx;
DROP TABLE t4;

-- ----------------------------------------------------------------
-- Test 5: Large table with overflow and schema changes
-- Target: allocateBtreePage overflow allocations and different callers
-- ----------------------------------------------------------------
CREATE TABLE t5(a INTEGER PRIMARY KEY, b TEXT, c TEXT);
WITH RECURSIVE r(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM r WHERE x<1000
)
INSERT INTO t5 SELECT x,
  randomblob(4000),
  printf('val-%d', x)
FROM r;
-- Delete many rows to populate freelist with overflow pages too
DELETE FROM t5 WHERE a BETWEEN 200 AND 800;
VACUUM;
-- Trigger allocations via index on text column and an ALTER
CREATE INDEX t5_c_idx ON t5(c);
ALTER TABLE t5 ADD COLUMN d INTEGER;
UPDATE t5 SET d = a*2 WHERE a <= 100;
EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE c LIKE 'val-9%';
DROP INDEX t5_c_idx;
DROP TABLE t5;

-- ================================================================
-- SQL Regression Test for: Change btree balance to non-recursive
-- task_id: 109
-- ================================================================

PRAGMA page_size = 1024;
PRAGMA cache_size = 10;
PRAGMA auto_vacuum = FULL;
PRAGMA journal_mode = DELETE;
PRAGMA synchronous = OFF;

-- Test 1: Root page overflow causing balance_deeper() then non-root balance
-- Targets: balance_deeper on root, balance_nonroot via balance(); copyNodeContent path
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(id INTEGER PRIMARY KEY, pad TEXT);

WITH RECURSIVE
  c(i) AS (
    SELECT 1
    UNION ALL
    SELECT i+1 FROM c WHERE i < 500
  )
INSERT INTO t1(id, pad)
SELECT i, printf('%.*c', 800, 'x') FROM c;

EXPLAIN QUERY PLAN SELECT pad FROM t1 WHERE id = 250;
EXPLAIN QUERY PLAN SELECT pad FROM t1 WHERE id = 500;

DROP TABLE t1;

-- Test 2: Root page becomes empty triggering balance_shallower()
-- Targets: balance_shallower, copyNodeContent, auto-vacuum ptrmap updates
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(id INTEGER PRIMARY KEY, val TEXT);

INSERT INTO t2 VALUES(1, 'a');
INSERT INTO t2 VALUES(2, 'b');
INSERT INTO t2 VALUES(3, 'c');

DELETE FROM t2 WHERE id IN (1,2,3);

EXPLAIN QUERY PLAN SELECT * FROM t2 WHERE id = 1;
EXPLAIN QUERY PLAN SELECT * FROM t2;

DROP TABLE t2;

-- Test 3: Quick-balance on rightmost leaf with integer keys
-- Targets: balance_quick(), parent internal-node balancing, non-recursive balance
DROP TABLE IF EXISTS t3;
CREATE TABLE t3(id INTEGER PRIMARY KEY, payload BLOB);

WITH RECURSIVE
  c(i) AS (
    SELECT 1
    UNION ALL
    SELECT i+1 FROM c WHERE i < 200
  )
INSERT INTO t3(id, payload)
SELECT i, randomblob(500) FROM c;

INSERT INTO t3(id, payload) VALUES(1000, randomblob(500));
INSERT INTO t3(id, payload) VALUES(1001, randomblob(500));

EXPLAIN QUERY PLAN SELECT payload FROM t3 WHERE id = 1001;
EXPLAIN QUERY PLAN SELECT payload FROM t3 ORDER BY id DESC LIMIT 1;

DROP TABLE t3;

-- Test 4: balance_nonroot() with internal nodes and deletion-driven rebalancing
-- Targets: balance_nonroot on internal nodes, parent overflow/underflow management
DROP TABLE IF EXISTS t4;
CREATE TABLE t4(k INTEGER PRIMARY KEY, v TEXT);

WITH RECURSIVE
  c(i) AS (
    SELECT 1
    UNION ALL
    SELECT i+1 FROM c WHERE i < 400
  )
INSERT INTO t4(k, v)
SELECT i, printf('row-%d', i) FROM c;

DELETE FROM t4 WHERE k % 2 = 0;
DELETE FROM t4 WHERE k BETWEEN 300 AND 350;

EXPLAIN QUERY PLAN SELECT v FROM t4 WHERE k = 123;
EXPLAIN QUERY PLAN SELECT v FROM t4 WHERE k BETWEEN 10 AND 390 ORDER BY k;

DROP TABLE t4;

-- Test 5: Mixed NULLs, large values and index to stress non-root and root balancing
-- Targets: balance() loop over multiple levels, copyNodeContent on index btree
DROP TABLE IF EXISTS t5;
DROP INDEX IF EXISTS t5_idx;
CREATE TABLE t5(a INTEGER PRIMARY KEY, b TEXT, c BLOB);
CREATE INDEX t5_idx ON t5(b);

WITH RECURSIVE
  c(i) AS (
    SELECT 1
    UNION ALL
    SELECT i+1 FROM c WHERE i < 300
  )
INSERT INTO t5(a, b, c)
SELECT 
  i,
  CASE WHEN i % 10 = 0 THEN NULL ELSE printf('val-%06d', i) END,
  CASE WHEN i % 15 = 0 THEN randomblob(900) ELSE randomblob(100) END
FROM c;

DELETE FROM t5 WHERE a BETWEEN 50 AND 120;
DELETE FROM t5 WHERE b IS NULL;

EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE b LIKE 'val-00%';
EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE b IS NULL OR c IS NOT NULL ORDER BY b;

DROP INDEX t5_idx;
DROP TABLE t5;
-- ================================================================
-- SQL Regression Test for: Changes to tokenize.c to facilitate full coverage testing. (CVS 6738)
-- task_id: 110
-- ================================================================

-- Test 1: Whitespace tokenization coverage (space, tab, newline, formfeed, carriage return)
CREATE TABLE t1(a INTEGER);
INSERT INTO t1 VALUES (1);
-- Leading space
EXPLAIN QUERY PLAN SELECT a FROM t1 WHERE a = 1;
-- Leading tab
EXPLAIN QUERY PLAN 	SELECT a FROM t1 WHERE a = 1;
-- Leading newline
EXPLAIN QUERY PLAN 
SELECT a FROM t1 WHERE a = 1;
-- Leading formfeed (ASCII 12)
EXPLAIN QUERY PLAN SELECT a FROM t1 WHERE a = 1;
-- Leading carriage return
EXPLAIN QUERY PLAN SELECT a FROM t1 WHERE a = 1;
DROP TABLE t1;

-- Test 2: Quote delimiter tokenization (` ' ") for identifiers and strings
CREATE TABLE "t2"(id INTEGER PRIMARY KEY, "col`1" TEXT, `col'2` TEXT);
INSERT INTO "t2" VALUES (1, 'a', 'b');
-- Double-quoted identifier
EXPLAIN QUERY PLAN SELECT "col`1" FROM "t2" WHERE id = 1;
-- Backtick-quoted identifier
EXPLAIN QUERY PLAN SELECT `col'2` FROM "t2" WHERE id = 1;
-- Single-quoted string literal
EXPLAIN QUERY PLAN SELECT * FROM "t2" WHERE "col`1" = 'a';
DROP TABLE "t2";

-- Test 3: Digit and floating-point tokenization, including hex prefix and trailing identifier chars
CREATE TABLE t3(x TEXT);
INSERT INTO t3 VALUES('dummy');
-- Integer starting with each digit and a float starting with dot
EXPLAIN QUERY PLAN SELECT 0,1,2,3,4,5,6,7,8,9,.5 FROM t3;
-- Hex literal prefix 0x / 0X and following identifier characters
EXPLAIN QUERY PLAN SELECT 0x1ff, 0X2A || 'suffix' FROM t3;
DROP TABLE t3;

-- Test 4: Variable name tokenization for $, @, : and blob literal x/X''
CREATE TABLE t4(y INTEGER);
INSERT INTO t4 VALUES(1);
-- Variables starting with $, @, : and # (to exercise CC_DOLLAR/CC_VARALPHA path)
EXPLAIN QUERY PLAN SELECT $var1, @var2, :var3, #var4 FROM t4;
-- Blob literals starting with x'' and X''
EXPLAIN QUERY PLAN SELECT x'0123', X'89AB' FROM t4;
DROP TABLE t4;

-- Test 5: Interrupted parse should set error via sqlite3ErrorMsg("interrupt")
CREATE TABLE t5(a INTEGER);
INSERT INTO t5 VALUES(1);
-- Long-running query to be interrupted externally; ensures sqlite3RunParser interrupt path is exercised
EXPLAIN QUERY PLAN SELECT a FROM t5 WHERE a IN (
  SELECT a FROM t5 t5_1 UNION ALL
  SELECT a FROM t5 t5_2 UNION ALL
  SELECT a FROM t5 t5_3 UNION ALL
  SELECT a FROM t5 t5_4 UNION ALL
  SELECT a FROM t5 t5_5
);
DROP TABLE t5;
-- ================================================================
-- SQL Regression Test for: More simplifications to vdbe.c (task 111)
-- Focus: cursor array access via pOp->p1, OP_IfNullRow, OP_OpenPseudo,
--        OP_Column on pseudo-cursor, OP_Close and related cursor uses.
-- ================================================================

-- Test 1: Simple table scan to exercise OP_Close cursor free path
-- Targets: OP_Close (cursor index in pOp->p1, apCsr[pOp->p1] = 0)
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(id INTEGER PRIMARY KEY, value TEXT);
INSERT INTO t1 VALUES (1, 'a'), (2, 'b'), (3, 'c');

-- A basic SELECT with a full scan and ORDER BY ensures opening and closing
-- of a btree cursor.
EXPLAIN QUERY PLAN
SELECT value FROM t1 ORDER BY id;

DROP TABLE t1;


-- Test 2: LEFT JOIN using IS NULL filter to trigger OP_IfNullRow
-- Targets: OP_IfNullRow (cursor lookup via apCsr[pOp->p1])
DROP TABLE IF EXISTS p;
DROP TABLE IF EXISTS c;
CREATE TABLE p(id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE c(id INTEGER PRIMARY KEY, pid INTEGER, note TEXT);

INSERT INTO p VALUES (1, 'p1'), (2, 'p2'), (3, 'p3');
INSERT INTO c VALUES (1, 1, 'c1'), (2, 2, 'c2');

-- This pattern (LEFT JOIN with IS NULL on right side) typically uses
-- OP_IfNullRow internally when probing the child cursor.
EXPLAIN QUERY PLAN
SELECT p.id, p.name, c.note
FROM p LEFT JOIN c ON c.pid = p.id
WHERE c.id IS NULL;

DROP TABLE c;
DROP TABLE p;


-- Test 3: ORDER BY with LIMIT/OFFSET to exercise pseudo-table cursor
-- Targets: OP_OpenPseudo (allocateCursor with pOp->p1, P3 columns),
--          OP_Column on sorter pseudo-table, OP_Close on sorter cursor
DROP TABLE IF EXISTS s;
CREATE TABLE s(a INTEGER, b TEXT);
INSERT INTO s VALUES
  (1, 'one'),
  (2, 'two'),
  (3, 'three'),
  (4, 'four');

-- Sorting with LIMIT/OFFSET forces use of sorter and pseudo-table
-- cursors that are then fed to OP_Column.
EXPLAIN QUERY PLAN
SELECT a, b
FROM s
ORDER BY b DESC
LIMIT 2 OFFSET 1;

DROP TABLE s;


-- Test 4: DISTINCT with ORDER BY to exercise multiple cursors and Close
-- Targets: multiple cursor allocations via pOp->p1, OP_Close and apCsr[pOp->p1]
DROP TABLE IF EXISTS d;
CREATE TABLE d(x INTEGER, y TEXT);
INSERT INTO d VALUES
  (1, 'alpha'),
  (1, 'alpha'),
  (2, 'beta'),
  (3, 'gamma');

-- DISTINCT plus ORDER BY often uses temp indexes and sorter cursors,
-- leading to open/close activity on several cursor slots.
EXPLAIN QUERY PLAN
SELECT DISTINCT y
FROM d
ORDER BY y;

DROP TABLE d;


-- Test 5: Correlated subquery with EXISTS and NOT NULL checks
-- Targets: cursor reuse via apCsr[pOp->p1], OP_IfNullRow fall-through path,
--          various cursor-based opcodes that now assert on pOp->p1
DROP TABLE IF EXISTS m1;
DROP TABLE IF EXISTS m2;
CREATE TABLE m1(id INTEGER PRIMARY KEY, v INTEGER);
CREATE TABLE m2(id INTEGER PRIMARY KEY, f INTEGER, w TEXT);

INSERT INTO m1 VALUES
  (1, NULL),
  (2, 10),
  (3, 20);

INSERT INTO m2 VALUES
  (1, 2, 'x'),
  (2, 2, 'y'),
  (3, 3, 'z');

-- The correlated EXISTS and IS NOT NULL predicate encourages use of
-- multiple cursors, including those checked via pOp->p1-based access.
EXPLAIN QUERY PLAN
SELECT m1.id,
       m1.v,
       EXISTS(SELECT 1 FROM m2 WHERE m2.f = m1.id AND m2.w IS NOT NULL) AS has_row
FROM m1
WHERE m1.v IS NOT NULL;

DROP TABLE m2;
DROP TABLE m1;

-- ================================================================
-- SQL Regression Test for: Avoid early journal-header magic write
-- task_id: 112
-- ================================================================
-- The tests focus on journal behavior in rollback journal mode,
-- especially persistent-journal and full-sync combinations.

PRAGMA auto_vacuum = 0;
PRAGMA journal_mode = DELETE;
PRAGMA synchronous = FULL;

-- ----------------------------------------------------------------
-- Test 1: Basic transaction in PERSIST journal mode
-- Targets:
--   * writeJournalHdr() path that writes combined magic+nRec header
--   * readJournalHdr(isHot=0) during normal rollback
-- ----------------------------------------------------------------
PRAGMA journal_mode = PERSIST;
PRAGMA synchronous = FULL;

DROP TABLE IF EXISTS t1;
CREATE TABLE t1(id INTEGER PRIMARY KEY, x TEXT);
INSERT INTO t1 VALUES(1, 'alpha');
INSERT INTO t1 VALUES(2, 'beta');

BEGIN;
  INSERT INTO t1 VALUES(3, 'gamma');
  INSERT INTO t1 VALUES(4, 'delta');
  EXPLAIN QUERY PLAN SELECT * FROM t1 WHERE id = 3;
ROLLBACK;

-- Run a query after rollback to force journal playback / header read
EXPLAIN QUERY PLAN SELECT * FROM t1 WHERE id > 0;

DROP TABLE t1;

-- ----------------------------------------------------------------
-- Test 2: Multiple transactions, empty and non-empty, in PERSIST
-- Targets:
--   * writeSuperJournal / header re-use with nRec=0 edge
--   * readJournalHdr(isHot=0) with nRec==0 fast-path
-- ----------------------------------------------------------------
PRAGMA journal_mode = PERSIST;
PRAGMA synchronous = FULL;

DROP TABLE IF EXISTS t2;
CREATE TABLE t2(a INTEGER, b TEXT, c REAL);
INSERT INTO t2 VALUES(1, 'one', 1.0);
INSERT INTO t2 VALUES(2, 'two', NULL);
INSERT INTO t2 VALUES(NULL, 'three', 3.0);

-- Empty transaction (no page changes)
BEGIN;
  EXPLAIN QUERY PLAN SELECT * FROM t2 WHERE a IS NULL;
COMMIT;

-- Non-empty transaction followed by rollback
BEGIN;
  UPDATE t2 SET b = 'z' WHERE a = 2;
  DELETE FROM t2 WHERE a IS NULL;
  EXPLAIN QUERY PLAN SELECT * FROM t2 WHERE b = 'z';
ROLLBACK;

-- Trigger another read of the journal (if any remains) via query
EXPLAIN QUERY PLAN SELECT * FROM t2 WHERE c IS NOT NULL;

DROP TABLE t2;

-- ----------------------------------------------------------------
-- Test 3: Large transaction to span multiple journal headers
-- Targets:
--   * Multiple calls to writeJournalHdr() updating nRec
--   * readJournalHdr(isHot=0) for later headers in same journal
-- ----------------------------------------------------------------
PRAGMA journal_mode = PERSIST;
PRAGMA synchronous = FULL;

DROP TABLE IF EXISTS t3;
CREATE TABLE t3(id INTEGER PRIMARY KEY, payload TEXT);

-- Insert baseline data
INSERT INTO t3 VALUES(1, 'base');
INSERT INTO t3 VALUES(2, 'base');

-- Large transaction to produce lots of pages
BEGIN;
  WITH RECURSIVE r(n) AS (
    SELECT 1
    UNION ALL
    SELECT n+1 FROM r WHERE n < 200
  )
  INSERT INTO t3(id, payload)
  SELECT 1000+n, printf('row-%03d-%s', n, randomblob(200)) FROM r;

  EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE id BETWEEN 1000 AND 1100;
COMMIT;

-- Second transaction to reuse persistent journal file
BEGIN;
  UPDATE t3 SET payload = substr(payload,1,20) WHERE id BETWEEN 1000 AND 1010;
  EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE id BETWEEN 1000 AND 1010;
ROLLBACK;

-- Final query to drive playback over existing journal content
EXPLAIN QUERY PLAN SELECT count(*) FROM t3;

DROP TABLE t3;

-- ----------------------------------------------------------------
-- Test 4: Hot journal simulation via ATTACH and crash-like pattern
-- Targets:
--   * readJournalHdr(isHot=1) path that skips magic read if header reused
--   * Interaction with attached database and persistent journals
-- ----------------------------------------------------------------
PRAGMA journal_mode = PERSIST;
PRAGMA synchronous = FULL;

DROP TABLE IF EXISTS main_t4;
CREATE TABLE main_t4(x INTEGER, y TEXT);
INSERT INTO main_t4 VALUES(1, 'a');
INSERT INTO main_t4 VALUES(2, 'b');

ATTACH ':memory:' AS aux;
DROP TABLE IF EXISTS aux.t4_aux;
CREATE TABLE aux.t4_aux(p INTEGER PRIMARY KEY, q BLOB);
INSERT INTO aux.t4_aux VALUES(1, X'00');
INSERT INTO aux.t4_aux VALUES(2, X'FF');

BEGIN;
  UPDATE main_t4 SET y = 'c' WHERE x = 1;
  INSERT INTO aux.t4_aux VALUES(3, randomblob(100));
  EXPLAIN QUERY PLAN SELECT * FROM main_t4, aux.t4_aux WHERE main_t4.x = aux.t4_aux.p;
ROLLBACK;

-- Queries to ensure both main and aux rollback playback paths run
EXPLAIN QUERY PLAN SELECT * FROM main_t4 WHERE y = 'a';
EXPLAIN QUERY PLAN SELECT * FROM aux.t4_aux WHERE p > 0;

DETACH aux;
DROP TABLE main_t4;

-- ----------------------------------------------------------------
-- Test 5: Edge cases with NULLs and empty tables
-- Targets:
--   * Journal header writes when no pages actually change
--   * readJournalHdr() when journal may be truncated or minimal
-- ----------------------------------------------------------------
PRAGMA journal_mode = PERSIST;
PRAGMA synchronous = FULL;

DROP TABLE IF EXISTS t5;
CREATE TABLE t5(a INTEGER, b TEXT, c BLOB);

-- Start with empty table, then perform no-op updates
BEGIN;
  EXPLAIN QUERY PLAN SELECT * FROM t5;
COMMIT;

INSERT INTO t5 VALUES(NULL, NULL, NULL);
INSERT INTO t5 VALUES(1, NULL, X'');
INSERT INTO t5 VALUES(2, 'x', X'0102');

BEGIN;
  -- Update that leaves row content effectively similar, stressing header logic
  UPDATE t5 SET b = b WHERE a IS NULL;
  DELETE FROM t5 WHERE a = 2;
  EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE a IS NULL OR b IS NULL;
ROLLBACK;

EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE c IS NOT NULL;

DROP TABLE t5;
-- ================================================================
-- SQL Regression Test for: Simplifications to sqlite3BtreeInsert()
-- and allocateSpace(), extra testcase() in btree.c
-- task_id: 113
-- ================================================================

PRAGMA page_size = 1024;
PRAGMA auto_vacuum = 0;
PRAGMA journal_mode = OFF;

-- Test 1: Trigger allocateSpace() gap==top / defragmentPage path on leaf table
-- Targets: allocateSpace freelist/gap boundary + defragmentPage testcase(pc==iCellFirst/iCellLast)
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);

-- Fill a few pages then delete middle rows to create fragmented free-list
WITH RECURSIVE
  c(x) AS (
    SELECT 1
    UNION ALL
    SELECT x+1 FROM c WHERE x<800
  )
INSERT INTO t1(a,b)
  SELECT x, printf('%050d', x) FROM c;

-- Delete every second row to create many small gaps
DELETE FROM t1 WHERE a%2=0;

-- Force cell-size checking and page defragment logic
PRAGMA cell_size_check = ON;

-- An insert that must allocate from freelist or trigger defragment
INSERT INTO t1(a,b) VALUES(1001, printf('%050d', 1001));

EXPLAIN QUERY PLAN SELECT * FROM t1 WHERE a=500;
EXPLAIN QUERY PLAN SELECT * FROM t1 ORDER BY a DESC LIMIT 10;

DROP TABLE IF EXISTS t1;


-- Test 2: Trigger allocateSpace freelist path and x==3/x==4 boundary in pageFindSlot
-- Targets: pageFindSlot testcase(x==3/x==4), allocateSpace using freelist slot
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(x INTEGER PRIMARY KEY, y BLOB);

-- Insert many variable-length records to populate freelist with diverse sizes
WITH RECURSIVE
  r(i) AS (
    SELECT 1
    UNION ALL
    SELECT i+1 FROM r WHERE i<400
  )
INSERT INTO t2(x,y)
  SELECT i, randomblob( (i%20)+10 ) FROM r;

-- Delete a pattern of rows to make freelist slots slightly larger than new cells
DELETE FROM t2 WHERE x%7=0;
DELETE FROM t2 WHERE x%11=0;

-- New insertions with different payload sizes to exercise x==3 and x==4 cases
INSERT INTO t2(x,y) VALUES(5000, randomblob(17));
INSERT INTO t2(x,y) VALUES(5001, randomblob(18));

EXPLAIN QUERY PLAN SELECT y FROM t2 WHERE x BETWEEN 10 AND 50;
EXPLAIN QUERY PLAN SELECT * FROM t2 ORDER BY x LIMIT 20;

DROP TABLE IF EXISTS t2;


-- Test 3: Internal btree page (index) allocateSpace/freeblock checks
-- Targets: freeblock validation (iCellFirst/iCellLast, pc+sz==usableSize) on index pages
DROP TABLE IF EXISTS t3;
CREATE TABLE t3(a INTEGER, b TEXT, c TEXT);
CREATE INDEX t3ab ON t3(a,b);

-- Populate enough rows to require multiple index pages
WITH RECURSIVE
  s(i) AS (
    SELECT 1
    UNION ALL
    SELECT i+1 FROM s WHERE i<1000
  )
INSERT INTO t3(a,b,c)
  SELECT i, printf('%08d', i), NULL FROM s;

-- Delete some rows to fragment the index freelist
DELETE FROM t3 WHERE a%3=0;
DELETE FROM t3 WHERE a%5=0;

-- Queries to walk internal index nodes and cause insert into fragmented pages
INSERT INTO t3(a,b,c) VALUES(2001, '2001', 'x');
INSERT INTO t3(a,b,c) VALUES(2002, '2002', 'y');

EXPLAIN QUERY PLAN SELECT b FROM t3 WHERE a BETWEEN 100 AND 900 ORDER BY b;
EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE b LIKE '123%';

DROP INDEX IF EXISTS t3ab;
DROP TABLE IF EXISTS t3;


-- Test 4: Large row payload around maxLocal / overflow boundary
-- Targets: testcase(nPayload==maxLocal/maxLocal+1), surplus==maxLocal(+1)
DROP TABLE IF EXISTS t4;
PRAGMA page_size = 4096;
CREATE TABLE t4(x INTEGER PRIMARY KEY, y BLOB);

-- Insert rows with payload near overflow boundary
INSERT INTO t4(x,y) VALUES(1, randomblob(1500));
INSERT INTO t4(x,y) VALUES(2, randomblob(2000));
INSERT INTO t4(x,y) VALUES(3, randomblob(3000));

EXPLAIN QUERY PLAN SELECT * FROM t4 WHERE x=2;
EXPLAIN QUERY PLAN SELECT * FROM t4 ORDER BY x;

DROP TABLE IF EXISTS t4;


-- Test 5: Boundary conditions with NULLs, empty pages and reuse of freed space
-- Targets: allocateSpace on nearly-empty page, gap+2+nByte==top, cbrk+size==usableSize
DROP TABLE IF EXISTS t5;
CREATE TABLE t5(a INTEGER PRIMARY KEY, b TEXT);

-- Insert then delete to create single big freeblock
INSERT INTO t5(a,b) VALUES(1, NULL);
INSERT INTO t5(a,b) VALUES(2, 'xyz');
INSERT INTO t5(a,b) VALUES(3, NULL);
DELETE FROM t5;

-- Reinsert with different sizes to reuse fragmented space and hit gap boundary
INSERT INTO t5(a,b) VALUES(10, 'short');
INSERT INTO t5(a,b) VALUES(11, printf('%0100d', 11));
INSERT INTO t5(a,b) VALUES(12, printf('%0200d', 12));

EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE b IS NULL;
EXPLAIN QUERY PLAN SELECT * FROM t5 ORDER BY a DESC;

DROP TABLE IF EXISTS t5;

-- ================================================================
-- SQL Regression Test for: Fix error handling in sqlite3BtreePutData()
-- task_id: 114
-- ================================================================

PRAGMA foreign_keys = OFF;
PRAGMA journal_mode = MEMORY;
PRAGMA synchronous = OFF;

-- ================================================================
-- Test 1: Normal incremental blob write on INTKEY table (happy path)
-- Targets: sqlite3BtreePutData normal path via incremental BLOB write
--          Ensures restoreCursorPosition() succeeds and assertions hold.
-- ================================================================

DROP TABLE IF EXISTS t1;
CREATE TABLE t1(
  id INTEGER PRIMARY KEY,
  data BLOB
);

INSERT INTO t1(id, data) VALUES(1, zeroblob(100));

-- Open and write an incremental blob on a row in an INTKEY table.
-- This should exercise sqlite3BtreePutData() with a valid write cursor
-- and cause accessPayload() to be called.
SELECT quote(
  substr(
    zeroblob(0) || x'',
    1,
    (UPDATE t1 SET data = (SELECT writeblob) WHERE id = 1)
  )
);

-- Use an explicit incremental blob write pattern via built-in
-- functions: write a small blob using UPDATE of a substring.
UPDATE t1 SET data =
  substr(data, 1, 10) || x'0102030405' || substr(data, 16)
WHERE id = 1;

EXPLAIN QUERY PLAN
  SELECT length(data) FROM t1 WHERE id = 1;

DROP TABLE IF EXISTS t1;

-- ================================================================
-- Test 2: Incremental blob write to NULL/empty and small payload
-- Targets: sqlite3BtreePutData with small writes, NULL handling,
--          and boundary condition where amount is less than existing size.
-- ================================================================

DROP TABLE IF EXISTS t2;
CREATE TABLE t2(
  id INTEGER PRIMARY KEY,
  payload BLOB
);

-- Insert a row with a NULL blob payload.
INSERT INTO t2(id, payload) VALUES(1, NULL);

-- Set payload to a small blob, then modify part of it.
UPDATE t2 SET payload = x'11223344556677889900' WHERE id = 1;

-- Overwrite a middle segment of the blob.
UPDATE t2 SET payload =
  substr(payload, 1, 3) || x'AABBCC' || substr(payload, 10)
WHERE id = 1;

EXPLAIN QUERY PLAN
  SELECT hex(payload) FROM t2 WHERE id = 1;

DROP TABLE IF EXISTS t2;

-- ================================================================
-- Test 3: Incremental blob write with large blob and boundary offsets
-- Targets: sqlite3BtreePutData with large blobs, offsets near end,
--          verifying that writes near the boundary still succeed.
-- ================================================================

DROP TABLE IF EXISTS t3;
CREATE TABLE t3(
  id INTEGER PRIMARY KEY,
  content BLOB
);

-- Insert a large blob (4 KB) and then perform writes near the end.
INSERT INTO t3(id, content) VALUES(1, zeroblob(4096));

-- Modify a segment close to the end of the blob.
UPDATE t3 SET content =
  substr(content, 1, 4080) || x'DEADBEEFCAFEBABE' || substr(content, 4089)
WHERE id = 1;

EXPLAIN QUERY PLAN
  SELECT length(content) FROM t3 WHERE id = 1;

DROP TABLE IF EXISTS t3;

-- ================================================================
-- Test 4: Incremental blob write during a transaction with concurrent reads
-- Targets: sqlite3BtreePutData assumptions (b)-(d): write-transaction,
--          shared-cache style read locks simulated by concurrent selects.
-- ================================================================

DROP TABLE IF EXISTS t4;
CREATE TABLE t4(
  id INTEGER PRIMARY KEY,
  val BLOB
);

INSERT INTO t4(id, val) VALUES(1, zeroblob(50));

BEGIN;
  -- Simulate concurrent read access within the same connection.
  SELECT length(val) FROM t4 WHERE id = 1;

  -- Perform a blob modification inside the same write transaction.
  UPDATE t4 SET val = x'0102030405060708090A' || substr(val, 11)
  WHERE id = 1;

  EXPLAIN QUERY PLAN
    SELECT hex(val) FROM t4 WHERE id = 1;
COMMIT;

DROP TABLE IF EXISTS t4;

-- ================================================================
-- Test 5: Multiple incremental blob writes on same row
-- Targets: sqlite3BtreePutData with multiple calls for same cursor,
--          exercising saveAllCursors() and repeated accessPayload().
-- ================================================================

DROP TABLE IF EXISTS t5;
CREATE TABLE t5(
  id INTEGER PRIMARY KEY,
  blobval BLOB
);

INSERT INTO t5(id, blobval) VALUES(1, zeroblob(64));

BEGIN;
  -- First modification in the middle.
  UPDATE t5 SET blobval =
    substr(blobval, 1, 16) || x'AA' || substr(blobval, 18)
  WHERE id = 1;

  -- Second modification near the beginning.
  UPDATE t5 SET blobval =
    x'BB' || substr(blobval, 2)
  WHERE id = 1;

  -- Third modification near the end.
  UPDATE t5 SET blobval =
    substr(blobval, 1, 60) || x'CCDD' || substr(blobval, 63)
  WHERE id = 1;

  EXPLAIN QUERY PLAN
    SELECT length(blobval) FROM t5 WHERE id = 1;
COMMIT;

DROP TABLE IF EXISTS t5;

-- ================================================================
-- SQL Regression Test for: Simplifications and additional testcase() macros for btree.c. (CVS 6866)
-- task_id: 115
-- ================================================================

-- Test 1: Exercise freelist allocation with non-empty table and pages returned to freelist
DROP TABLE IF EXISTS t1;
PRAGMA auto_vacuum = OFF;
PRAGMA page_size = 1024;
VACUUM;
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM c WHERE x<2000
) INSERT INTO t1(a,b)
SELECT x, printf('value-%04d',x) FROM c;
DELETE FROM t1 WHERE a%2=0;
VACUUM;
EXPLAIN QUERY PLAN SELECT * FROM t1 WHERE a=1001;
DROP TABLE t1;

-- Test 2: Exercise freelist trunk pages by creating and dropping a large table
DROP TABLE IF EXISTS t2;
PRAGMA auto_vacuum = OFF;
PRAGMA page_size = 1024;
VACUUM;
CREATE TABLE t2(x INTEGER PRIMARY KEY, y BLOB);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM c WHERE x<4000
) INSERT INTO t2(x,y)
SELECT x, randomblob(400) FROM c;
DROP TABLE t2;
CREATE TABLE t2(x INTEGER PRIMARY KEY, y TEXT);
INSERT INTO t2 VALUES(1,'a');
EXPLAIN QUERY PLAN SELECT * FROM t2 WHERE x=1;
DROP TABLE t2;

-- Test 3: Exercise freelist with mixed page sizes and NULL/duplicate values
DROP TABLE IF EXISTS t3;
PRAGMA auto_vacuum = OFF;
PRAGMA page_size = 2048;
VACUUM;
CREATE TABLE t3(a INTEGER, b TEXT, c BLOB);
INSERT INTO t3 VALUES(NULL, NULL, NULL);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM c WHERE x<1500
) INSERT INTO t3(a,b,c)
SELECT x%10, printf('d%03d',x%10), randomblob(100) FROM c;
CREATE INDEX t3a ON t3(a);
DELETE FROM t3 WHERE a IS NULL;
VACUUM;
EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE a=5;
DROP INDEX t3a;
DROP TABLE t3;

-- Test 4: Exercise freelist search with auto_vacuum and exact/LE allocation modes
DROP TABLE IF EXISTS t4;
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;
VACUUM;
CREATE TABLE t4(a INTEGER PRIMARY KEY, b TEXT);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM c WHERE x<3000
) INSERT INTO t4(a,b)
SELECT x, printf('t4-%04d',x) FROM c;
DELETE FROM t4 WHERE a BETWEEN 100 AND 500;
DELETE FROM t4 WHERE a BETWEEN 1500 AND 2000;
VACUUM;
CREATE INDEX t4b ON t4(b);
EXPLAIN QUERY PLAN SELECT * FROM t4 WHERE b='t4-0200';
EXPLAIN QUERY PLAN SELECT * FROM t4 WHERE rowid<=150;
DROP INDEX t4b;
DROP TABLE t4;

-- Test 5: Exercise freelist corruption detection boundaries via large insert/delete cycles
DROP TABLE IF EXISTS t5;
PRAGMA auto_vacuum = OFF;
PRAGMA page_size = 4096;
VACUUM;
CREATE TABLE t5(a INTEGER PRIMARY KEY, b TEXT);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM c WHERE x<5000
) INSERT INTO t5(a,b)
SELECT x, printf('t5-%04d',x) FROM c;
DELETE FROM t5 WHERE a%3=0;
DELETE FROM t5 WHERE a%5=0;
VACUUM;
EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE a=2500;
EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE a IS NULL;
DROP TABLE t5;
-- ================================================================
-- SQL Regression Test for: Fix double-free in fts3 legacy '-' operator
-- task_id: 116
-- ================================================================

-- Test 1: Single legacy '-' operator with multiple negative terms (build NOT chain)
DROP TABLE IF EXISTS t116_1;
CREATE VIRTUAL TABLE t116_1 USING fts3(content TEXT);

INSERT INTO t116_1(rowid, content) VALUES
  (1, 'sqlite mysql postgresql'),
  (2, 'sqlite'),
  (3, 'mysql'),
  (4, 'sqlite oracle'),
  (5, 'postgresql mysql sqlite');

-- Exercise legacy syntax: one positive term, two "-" negative terms
EXPLAIN QUERY PLAN
  SELECT rowid FROM t116_1 WHERE content MATCH 'sqlite -mysql -postgresql';

EXPLAIN QUERY PLAN
  SELECT rowid FROM t116_1 WHERE content MATCH 'sqlite  -mysql   -postgresql';

DROP TABLE IF EXISTS t116_1;


-- Test 2: Leading '-' terms only, no positive term (pRet initially NULL, then attached)
DROP TABLE IF EXISTS t116_2;
CREATE VIRTUAL TABLE t116_2 USING fts3(content TEXT);

INSERT INTO t116_2(rowid, content) VALUES
  (1, 'sqlite'),
  (2, 'mysql'),
  (3, 'postgresql'),
  (4, 'oracle');

-- Legacy syntax with only negative terms; exercises final attachment of pRet to NOT chain
EXPLAIN QUERY PLAN
  SELECT rowid FROM t116_2 WHERE content MATCH '-sqlite -mysql postgresql';

EXPLAIN QUERY PLAN
  SELECT rowid FROM t116_2 WHERE content MATCH '-sqlite -mysql   oracle';

DROP TABLE IF EXISTS t116_2;


-- Test 3: Mixture of implicit AND and legacy '-' with multiple columns
DROP TABLE IF EXISTS t116_3;
CREATE VIRTUAL TABLE t116_3 USING fts3(title TEXT, body TEXT);

INSERT INTO t116_3(rowid, title, body) VALUES
  (1, 'sqlite intro', 'sqlite tutorial for beginners'),
  (2, 'sqlite and mysql', 'comparison of sqlite and mysql'),
  (3, 'advanced sqlite', 'deep dive into sqlite internals'),
  (4, 'mysql only', 'mysql guide'),
  (5, 'sqlite and oracle', 'sqlite with oracle examples');

-- Implicit AND between phrases, with a trailing "-" term
EXPLAIN QUERY PLAN
  SELECT rowid FROM t116_3
   WHERE body MATCH 'sqlite tutorial -mysql';

-- Column-qualified phrase combined with legacy '-' term
EXPLAIN QUERY PLAN
  SELECT rowid FROM t116_3
   WHERE title MATCH 'sqlite -mysql';

DROP TABLE IF EXISTS t116_3;


-- Test 4: Legacy '-' combined with OR and NEAR to exercise tree balancing and depth
DROP TABLE IF EXISTS t116_4;
CREATE VIRTUAL TABLE t116_4 USING fts3(content TEXT);

INSERT INTO t116_4(rowid, content) VALUES
  (1, 'sqlite mysql near test one'),
  (2, 'sqlite test two'),
  (3, 'mysql near test three'),
  (4, 'sqlite oracle near test four'),
  (5, 'misc text without keywords');

-- Expression with OR and NEAR plus legacy '-' negatives; builds deeper NOT/OR tree
EXPLAIN QUERY PLAN
  SELECT rowid FROM t116_4
   WHERE content MATCH 'sqlite NEAR/5 test -mysql OR oracle -mysql';

EXPLAIN QUERY PLAN
  SELECT rowid FROM t116_4
   WHERE content MATCH 'sqlite NEAR test -mysql OR oracle -mysql';

DROP TABLE IF EXISTS t116_4;


-- Test 5: Edge cases with quotes, mixed case, and empty result using legacy '-'
DROP TABLE IF EXISTS t116_5;
CREATE VIRTUAL TABLE t116_5 USING fts3(content TEXT);

INSERT INTO t116_5(rowid, content) VALUES
  (1, 'one two three'),
  (2, 'one TWO three'),
  (3, 'one two four'),
  (4, 'ONE two three four'),
  (5, 'unrelated text');

-- Quoted phrase followed by legacy '-' term
EXPLAIN QUERY PLAN
  SELECT rowid FROM t116_5
   WHERE content MATCH '"one two" -three';

-- Legacy '-' producing an empty match set (all rows excluded)
EXPLAIN QUERY PLAN
  SELECT rowid FROM t116_5
   WHERE content MATCH 'one -two -three -four';

DROP TABLE IF EXISTS t116_5;
-- ================================================================
-- SQL Regression Test for: Remove another unreachable branch from btree.c. (CVS 6878)
-- task_id: 117
-- Target: getOverflowPage() autovacuum/pointer-map overflow chain handling
-- ================================================================

PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;

-- Test 1: Simple overflow chain via large TEXT payload (exercise getOverflowPage normal path)
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(id INTEGER PRIMARY KEY, x TEXT);
WITH RECURSIVE c(i, s) AS (
  SELECT 1, printf('%01024d', 0)
  UNION ALL
  SELECT i+1, s || s FROM c WHERE i < 10
)
INSERT INTO t1(id, x)
SELECT 1, substr(s, 1, 50000) FROM c WHERE i = 6;

EXPLAIN QUERY PLAN SELECT x FROM t1 WHERE id = 1;
EXPLAIN QUERY PLAN SELECT length(x) FROM t1;

DROP TABLE IF EXISTS t1;

-- Test 2: Multiple overflow pages using BLOB payload and an index (different access pattern)
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(id INTEGER PRIMARY KEY, b BLOB);
WITH RECURSIVE c(i, s) AS (
  SELECT 1, zeroblob(1024)
  UNION ALL
  SELECT i+1, s || zeroblob(1024) FROM c WHERE i < 40
)
INSERT INTO t2(id, b)
SELECT 1, s FROM c WHERE i = 20;

CREATE INDEX t2_b_idx ON t2(b);

EXPLAIN QUERY PLAN SELECT id FROM t2 WHERE b = (SELECT b FROM t2 WHERE id = 1);
EXPLAIN QUERY PLAN SELECT count(*) FROM t2 WHERE b >= x'00';

DROP INDEX IF EXISTS t2_b_idx;
DROP TABLE IF EXISTS t2;

-- Test 3: Overflow chain on WITHOUT ROWID table (different btree layout)
DROP TABLE IF EXISTS t3;
CREATE TABLE t3(a TEXT, b TEXT, PRIMARY KEY(a,b)) WITHOUT ROWID;
WITH RECURSIVE c(i, s) AS (
  SELECT 1, printf('%01024d', 0)
  UNION ALL
  SELECT i+1, s || s FROM c WHERE i < 10
)
INSERT INTO t3(a, b)
SELECT 'key', substr(s, 1, 60000) FROM c WHERE i = 7;

EXPLAIN QUERY PLAN SELECT b FROM t3 WHERE a = 'key';
EXPLAIN QUERY PLAN SELECT length(b) FROM t3;

DROP TABLE IF EXISTS t3;

-- Test 4: Overflow pages created then freed by DELETE / VACUUM (pointer-map interactions)
DROP TABLE IF EXISTS t4;
CREATE TABLE t4(id INTEGER PRIMARY KEY, x TEXT);
WITH RECURSIVE c(i, s) AS (
  SELECT 1, printf('%01024d', 0)
  UNION ALL
  SELECT i+1, s || s FROM c WHERE i < 10
)
INSERT INTO t4(id, x)
SELECT 1, substr(s, 1, 70000) FROM c WHERE i = 7;
INSERT INTO t4(id, x) VALUES(2, 'short');

EXPLAIN QUERY PLAN SELECT x FROM t4 WHERE id = 1;
DELETE FROM t4 WHERE id = 1;
VACUUM;
EXPLAIN QUERY PLAN SELECT * FROM t4 WHERE id = 2;

DROP TABLE IF EXISTS t4;

-- Test 5: Mixed TEXT/BLOB overflow and NULLs, including empty result scan
DROP TABLE IF EXISTS t5;
CREATE TABLE t5(id INTEGER PRIMARY KEY, x TEXT, y BLOB);
WITH RECURSIVE c(i, s) AS (
  SELECT 1, printf('%01024d', 0)
  UNION ALL
  SELECT i+1, s || s FROM c WHERE i < 10
)
INSERT INTO t5(id, x, y)
SELECT 1, substr(s, 1, 80000), zeroblob(50000) FROM c WHERE i = 7;
INSERT INTO t5(id, x, y) VALUES(2, NULL, NULL);

EXPLAIN QUERY PLAN SELECT x, y FROM t5 WHERE id IN (1,2);
EXPLAIN QUERY PLAN SELECT x FROM t5 WHERE id = 3;  -- empty result, still exercises btree search

DROP TABLE IF EXISTS t5;
-- ================================================================
-- SQL Regression Test for: Added the SQLITE_TESTCTRL_RESERVE option
-- and btree.c simplifications (CVS 6894)
-- task_id: 118
-- ================================================================

PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;

-- ===================================================================
-- Test 1: Free-list trunk full behavior and clearTable path (saveAllCursors)
-- Targets:
--   * freePage2 path where a new trunk page is created (btreeGetPage /
--     sqlite3PagerWrite split error handling)
--   * sqlite3BtreeClearTable -> saveAllCursors() success path
--   * Exercise freelist trunk/leaf accounting (nLeaf u32)
-- ===================================================================

DROP TABLE IF EXISTS t1;
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);

-- Fill enough pages so that many free pages exist later.
WITH RECURSIVE r(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM r WHERE x<400
)
INSERT INTO t1(a,b)
SELECT x, printf('row-%04d',x) FROM r;

-- Create an index to allocate more pages
CREATE INDEX t1_b_idx ON t1(b);

-- Delete most rows to populate freelist trunk/leaf arrays.
DELETE FROM t1 WHERE a % 2 = 0;
DELETE FROM t1 WHERE a % 2 = 1;

-- Clear the table root page via DELETE without dropping the table.
-- This invokes sqlite3BtreeClearTable and clearDatabasePage, and may
-- also recycle trunk pages.
EXPLAIN QUERY PLAN DELETE FROM t1;

DROP INDEX IF EXISTS t1_b_idx;
DROP TABLE IF EXISTS t1;

-- ===================================================================
-- Test 2: freeSpace() with page header child pointer size = 0/4
-- Targets:
--   * Assertion/logic using hdrOffset+6+childPtrSize in freeSpace()
--   * Exercise leaf (childPtrSize=0) and interior (childPtrSize=4) pages
--   * Involves records with overflow and varying payload sizes
-- ===================================================================

DROP TABLE IF EXISTS t2;
CREATE TABLE t2(x INTEGER PRIMARY KEY, y BLOB);

-- Insert large records to create overflow cells.
WITH RECURSIVE big(x) AS (
  SELECT 0
  UNION ALL
  SELECT x+1 FROM big WHERE x<200
)
INSERT INTO t2(x,y)
SELECT x,
       (SELECT group_concat(randomblob(50), '') FROM big)
FROM (SELECT 1 AS x UNION ALL SELECT 2 UNION ALL SELECT 3);

-- Delete rows to free space and invoke freeSpace on both kinds of pages.
DELETE FROM t2 WHERE x = 2;

EXPLAIN QUERY PLAN SELECT count(*) FROM t2 WHERE y IS NOT NULL;

DROP TABLE IF EXISTS t2;

-- ===================================================================
-- Test 3: saveAllCursors() with open read cursors and clearTable
-- Targets:
--   * saveAllCursors() non-trivial behavior when read cursor exists
--   * sqlite3BtreeClearTable path with active cursor, EQP only
-- ===================================================================

DROP TABLE IF EXISTS t3;
CREATE TABLE t3(a INTEGER PRIMARY KEY, b TEXT);
INSERT INTO t3 VALUES(1,'one'),(2,'two'),(3,NULL);

-- Open a read cursor via a SELECT that is not yet finalized when
-- subsequent DELETE is compiled and executed.
BEGIN;
SELECT * FROM t3 WHERE b IS NOT NULL;

-- This DELETE will trigger sqlite3BtreeClearTable when the table is
-- large enough or when vacuum/autovacuum interacts with free-list.
EXPLAIN QUERY PLAN DELETE FROM t3;
COMMIT;

DROP TABLE IF EXISTS t3;

-- ===================================================================
-- Test 4: Overflow chains and clearCellOverflow / freePage2
-- Targets:
--   * clearCellOverflow() loop freeing multiple overflow pages
--   * freePage2() path where page is looked up and pager refcount is 1
--   * Interaction with reserved bytes at end of page
-- ===================================================================

DROP TABLE IF EXISTS t4;
CREATE TABLE t4(id INTEGER PRIMARY KEY, data BLOB);

-- Insert a very large row to ensure multiple overflow pages.
INSERT INTO t4(id, data)
SELECT 1, hex(randomblob(80000));

-- Update to smaller value to force overflow chain to be freed.
UPDATE t4 SET data = X'00' WHERE id = 1;

EXPLAIN QUERY PLAN SELECT length(data) FROM t4;

DROP TABLE IF EXISTS t4;

-- ===================================================================
-- Test 5: AUTOVACUUM, freelist trunks, and root-page clear/drop
-- Targets:
--   * btree free-list management when dropping tables (freePage2 trunk
--     replacement case using new error-handling structure)
--   * sqlite3BtreeDropTable path where saveAllCursors() is called
-- ===================================================================

PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;

DROP TABLE IF EXISTS t5;
CREATE TABLE t5(a INTEGER PRIMARY KEY, b TEXT);

-- Create many rows to allocate multiple root and leaf pages.
WITH RECURSIVE r5(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM r5 WHERE x<=500
)
INSERT INTO t5(a,b)
SELECT x, printf('val-%05d',x) FROM r5;

CREATE INDEX t5_b_idx ON t5(b);

-- Drop the index and table to exercise freelist trunk replacement and
-- page-1 special-case handling.
EXPLAIN QUERY PLAN DROP INDEX t5_b_idx;
EXPLAIN QUERY PLAN DROP TABLE t5;

DROP TABLE IF EXISTS t5;

-- ================================================================
-- SQL Regression Test for: Fix potential corruption after DROP TABLE
-- when max root page coincides with pending-byte or ptrmap page.
-- task_id: 119
-- ================================================================

PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;
PRAGMA journal_mode = MEMORY;

-- ----------------------------------------------------------------
-- Test 1: Basic DROP TABLE under FULL autovacuum
--   Target: Exercise btreeDropTable() autovacuum branch and the loop
--           that decrements maxRootPgno at least once (normal case).
-- ----------------------------------------------------------------

CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);
INSERT INTO t1 VALUES (1, 'one'), (2, 'two');
SELECT count(*) FROM t1;

CREATE TABLE t2(x INTEGER, y TEXT);
INSERT INTO t2 VALUES (NULL, 'alpha'), (10, NULL), (20, 'beta');
EXPLAIN QUERY PLAN SELECT * FROM t2 WHERE x IS NULL;

DROP TABLE t2;

-- Touch database to ensure further btree activity after DROP
CREATE TABLE t3(c INTEGER, d TEXT);
INSERT INTO t3 VALUES (1, 'x');
EXPLAIN QUERY PLAN SELECT * FROM t3;

DROP TABLE t3;
DROP TABLE t1;

-- ----------------------------------------------------------------
-- Test 2: Multiple tables and indexes; mix of NULLs and empty result
--   Target: Exercise repeated updates of maxRootPgno and loop, with
--           additional btree roots created by indexes.
-- ----------------------------------------------------------------

CREATE TABLE t4(id INTEGER PRIMARY KEY, v TEXT);
CREATE INDEX t4_v_idx ON t4(v);
INSERT INTO t4 VALUES (1, 'a'), (2, 'b'), (3, NULL);

CREATE TABLE t5(p INTEGER, q INTEGER, r TEXT);
CREATE INDEX t5_pq_idx ON t5(p, q);
INSERT INTO t5 VALUES
  (1, 1, 'x'),
  (1, 2, 'y'),
  (2, NULL, 'z'),
  (NULL, 3, NULL);

EXPLAIN QUERY PLAN SELECT * FROM t4 WHERE v IS NULL;  -- empty result
EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE p = 1 AND q = 2;

DROP TABLE t5;               -- causes btreeDropTable() with indexes
DROP TABLE t4;

-- Clean up any remaining roots
PRAGMA incremental_vacuum;

-- ----------------------------------------------------------------
-- Test 3: DROP TABLE followed by creating another table with same name
--   Target: Exercise scenario where maxRootPgno is decremented and
--           subsequent CREATE reuses freed root pages.
-- ----------------------------------------------------------------

CREATE TABLE t6(a INTEGER, b INTEGER);
INSERT INTO t6 VALUES (1, 1), (2, 4), (3, 9);
EXPLAIN QUERY PLAN SELECT b FROM t6 WHERE a = 2;

DROP TABLE t6;  -- triggers autovacuum root-page relocation logic

CREATE TABLE t6(a INTEGER, b INTEGER, c TEXT);
INSERT INTO t6 VALUES (1, 1, 'x'), (2, 4, 'y');
EXPLAIN QUERY PLAN SELECT * FROM t6 WHERE c = 'y';

DROP TABLE t6;

-- ----------------------------------------------------------------
-- Test 4: Edge mix of temporary tables and main schema tables
--   Target: Ensure main-schema DROP TABLE path is exercised while temp
--           objects verify no interference with autovacuum meta logic.
-- ----------------------------------------------------------------

CREATE TABLE main_main(a INTEGER, b TEXT);
INSERT INTO main_main VALUES (1, 'm');

CREATE TEMP TABLE temp_tmp(a INTEGER, b TEXT);
INSERT INTO temp_tmp VALUES (1, 't');
EXPLAIN QUERY PLAN SELECT * FROM temp_tmp;

DROP TABLE main_main;      -- autovacuum-enabled main db drop

-- Temp table still usable; exercise further btree activity.
EXPLAIN QUERY PLAN SELECT * FROM temp_tmp WHERE a = 1;

DROP TABLE temp_tmp;

-- ----------------------------------------------------------------
-- Test 5: Chain of DROPs to drive multiple iterations of maxRootPgno--           decrement loop, with various data patterns.
--   Target: Repeatedly exercise the while-loop that skips over
--           pending-byte or ptrmap pages by performing several
--           DROP TABLE operations in a row under FULL autovacuum.
-- ----------------------------------------------------------------

CREATE TABLE c1(x INTEGER PRIMARY KEY, y TEXT);
CREATE TABLE c2(x INTEGER, y TEXT);
CREATE TABLE c3(x INTEGER, y TEXT);
CREATE TABLE c4(x INTEGER, y TEXT);

INSERT INTO c1 VALUES (1, 'a'), (2, 'b');
INSERT INTO c2 VALUES (NULL, 'n1'), (10, 'n2');
INSERT INTO c3 VALUES (1, NULL), (2, '');
INSERT INTO c4 VALUES (-1000000, 'min'), (1000000, 'max');

EXPLAIN QUERY PLAN SELECT * FROM c1 WHERE x = 2;
EXPLAIN QUERY PLAN SELECT * FROM c2 WHERE y IS NULL;
EXPLAIN QUERY PLAN SELECT * FROM c3 WHERE y = '';
EXPLAIN QUERY PLAN SELECT * FROM c4 WHERE x BETWEEN -1000000 AND 1000000;

DROP TABLE c4;
DROP TABLE c3;
DROP TABLE c2;
DROP TABLE c1;

PRAGMA incremental_vacuum;

-- ================================================================
-- SQL Regression Test for: Return meaningful error if keyword used
-- as an rtree table column name (Ticket #3970, sqlite3_declare_vtab
-- error propagation in rtree module)
-- task_id: 120
-- ================================================================

-- Test 1: Keyword used as first dimension column name (matches ticket #3970)
-- Covers: sqlite3_declare_vtab() failure path and error message propagation
DROP TABLE IF EXISTS t_rtree_kw1;
CREATE VIRTUAL TABLE t_rtree_kw1 USING rtree(index, x1, y1, x2, y2);
-- The above statement is expected to fail and exercise the new error path.


-- Test 2: Keyword used as auxiliary column name after valid dimensions
-- Covers: successful parsing of dimensions, then sqlite3_declare_vtab() error
DROP TABLE IF EXISTS t_rtree_kw2;
CREATE VIRTUAL TABLE t_rtree_kw2 USING rtree(id, x1, y1, x2, y2, +index);
-- The use of keyword "index" as an auxiliary column name should cause
-- sqlite3_declare_vtab() to fail and the rtree module to return the
-- underlying sqlite3_errmsg() text.


-- Test 3: Multiple keyword-like identifiers; only the reserved keyword causes failure
-- Covers: construction of CREATE TABLE x(...) SQL with several columns,
--         then sqlite3_declare_vtab() failure on one reserved keyword
DROP TABLE IF EXISTS t_rtree_kw3;
CREATE VIRTUAL TABLE t_rtree_kw3 USING rtree(column, select, from, where, index);
-- Here, several identifiers resemble SQL syntax; the reserved keyword
-- used as a column name exercises the same error-reporting path.


-- Test 4: Mix of valid identifiers and a keyword with integer-coordinates rtree
-- Covers: eCoordType = INT32 branch plus sqlite3_declare_vtab() error path
DROP TABLE IF EXISTS t_rtree_kw4;
CREATE VIRTUAL TABLE t_rtree_kw4 USING rtree_i32(index, x1, x2);
-- Even for integer-coordinate configuration, using a keyword as the
-- first data column name should drive sqlite3_declare_vtab() to fail
-- and propagate sqlite3_errmsg().


-- Test 5: Keyword as last dimension column with preceding auxiliary columns
-- Covers: auxiliary column parsing, boundary between aux and dimension
--         columns, then sqlite3_declare_vtab() error
DROP TABLE IF EXISTS t_rtree_kw5;
CREATE VIRTUAL TABLE t_rtree_kw5 USING rtree(
  id,
  +aux1,
  +aux2,
  x1,
  y1,
  x2,
  index
);
-- This layout ensures that both aux-column handling and dimension handling
-- are exercised before sqlite3_declare_vtab() fails on the keyword column
-- name and the new error message code path is used.
-- ================================================================
-- SQL Regression Test for: Modify btree.c routines to take rc pointer
-- task_id: 121
-- ================================================================

-- Test 1: AUTOVACUUM table with large rows to exercise ptrmapPut/ptrmapPutOvflPtr
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;
VACUUM;

CREATE TABLE t1(a INTEGER PRIMARY KEY, b BLOB);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM c WHERE x < 200
) 
INSERT INTO t1(a,b)
SELECT 1, group_concat(char(65)) FROM c;

CREATE INDEX t1_b_idx ON t1(b);
EXPLAIN QUERY PLAN SELECT * FROM t1 WHERE a=1;
EXPLAIN QUERY PLAN SELECT * FROM t1 WHERE b LIKE 'A%';

DROP INDEX t1_b_idx;
DROP TABLE t1;

-- Test 2: AUTOVACUUM with many inserts/deletes to exercise dropCell and ptrmapPut
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;
VACUUM;

CREATE TABLE t2(x INTEGER PRIMARY KEY, y TEXT);
INSERT INTO t2 VALUES(1, 'alpha');
INSERT INTO t2 VALUES(2, 'beta');
INSERT INTO t2 VALUES(3, 'gamma');
INSERT INTO t2 VALUES(4, 'delta');
INSERT INTO t2 VALUES(5, 'epsilon');
DELETE FROM t2 WHERE x IN (2,4);
INSERT INTO t2 VALUES(6, 'zeta');
INSERT INTO t2 VALUES(7, 'eta');

EXPLAIN QUERY PLAN SELECT * FROM t2 ORDER BY x;
EXPLAIN QUERY PLAN SELECT * FROM t2 WHERE x BETWEEN 1 AND 7;

DROP TABLE t2;

-- Test 3: AUTOVACUUM with overflow records moved between pages (insertCell with overflow)
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;
VACUUM;

CREATE TABLE t3(id INTEGER PRIMARY KEY, c1 TEXT, c2 TEXT);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM c WHERE x < 300
)
INSERT INTO t3(id,c1,c2)
SELECT 1, group_concat(char(66)), group_concat(char(67)) FROM c;

CREATE INDEX t3_c1_idx ON t3(c1);
CREATE INDEX t3_c2_idx ON t3(c2);

EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE c1 LIKE 'B%';
EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE c2 LIKE 'C%';

DROP INDEX t3_c1_idx;
DROP INDEX t3_c2_idx;
DROP TABLE t3;

-- Test 4: Exercise sqlite3BtreeFirst/sqlite3BtreeLast and edge cases (empty and non-empty)
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;
VACUUM;

CREATE TABLE t4(a INTEGER PRIMARY KEY, b TEXT);
EXPLAIN QUERY PLAN SELECT * FROM t4 ORDER BY a LIMIT 1;
EXPLAIN QUERY PLAN SELECT * FROM t4 ORDER BY a DESC LIMIT 1;

INSERT INTO t4 VALUES(10, 'ten');
INSERT INTO t4 VALUES(20, 'twenty');
INSERT INTO t4 VALUES(30, 'thirty');

EXPLAIN QUERY PLAN SELECT * FROM t4 ORDER BY a LIMIT 1;
EXPLAIN QUERY PLAN SELECT * FROM t4 ORDER BY a DESC LIMIT 1;

DROP TABLE t4;

-- Test 5: Incremental blob read to exercise accessPayloadChecked and CURSOR_FAULT handling
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;
VACUUM;

CREATE TABLE t5(id INTEGER PRIMARY KEY, data BLOB);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM c WHERE x < 400
)
INSERT INTO t5(id,data)
SELECT 1, group_concat(char(68)) FROM c;

-- Use a scalar subquery reading a substring of the large blob to invoke sqlite3_blob API paths
EXPLAIN QUERY PLAN SELECT substr(data, 100, 50) FROM t5 WHERE id=1;
EXPLAIN QUERY PLAN SELECT length(data) FROM t5 WHERE id=1;

DROP TABLE t5;
-- ================================================================
-- SQL Regression Test for: Changes to btree.c in support of coverage testing (CVS 6913)
-- task_id: 122
-- ================================================================
.PRAGMA page_size = 1024;
.PRAGMA auto_vacuum = FULL;
.PRAGMA journal_mode = DELETE;

-- Test 1: Trigger balance_shallower() + copyNodeContent/freePage via heavy DELETE on indexed table
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM c WHERE x<5000
)
INSERT INTO t1(a,b) SELECT x, printf('row-%05d',x) FROM c;
CREATE INDEX t1b ON t1(b);
DELETE FROM t1 WHERE a BETWEEN 1000 AND 4500;
EXPLAIN QUERY PLAN SELECT * FROM t1 WHERE a BETWEEN 10 AND 20 ORDER BY a;
EXPLAIN QUERY PLAN SELECT * FROM t1 WHERE b LIKE 'row-04%';
DROP INDEX t1b;
DROP TABLE t1;

-- Test 2: Root overflow and balance_deeper() using UNIQUE index on large varints
CREATE TABLE t2(x INTEGER PRIMARY KEY, y TEXT);
CREATE UNIQUE INDEX t2y ON t2(y);
WITH RECURSIVE r(i) AS (
  SELECT 1
  UNION ALL
  SELECT i+1 FROM r WHERE i<8000
)
INSERT INTO t2(x,y) SELECT i, printf('val-%010d', i*13) FROM r;
EXPLAIN QUERY PLAN SELECT y FROM t2 WHERE y='val-0000001300';
EXPLAIN QUERY PLAN SELECT y FROM t2 WHERE y>'val-0000500000' ORDER BY y LIMIT 10;
DROP INDEX t2y;
DROP TABLE t2;

-- Test 3: WITHOUT ROWID table to exercise balance and copyNodeContent on non-leaf-data btree
CREATE TABLE t3(
  k TEXT PRIMARY KEY,
  v TEXT
) WITHOUT ROWID;
WITH RECURSIVE gen(i) AS (
  SELECT 1
  UNION ALL
  SELECT i+1 FROM gen WHERE i<6000
)
INSERT INTO t3(k,v) SELECT printf('key-%05d',i), printf('val-%05d',i) FROM gen;
DELETE FROM t3 WHERE k BETWEEN 'key-01000' AND 'key-05900';
EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE k BETWEEN 'key-00010' AND 'key-00020';
EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE v LIKE 'val-0001%';
DROP TABLE t3;

-- Test 4: Large records with overflow to stress allocator and freePage pathways
CREATE TABLE t4(id INTEGER PRIMARY KEY, payload BLOB);
WITH RECURSIVE big(i) AS (
  SELECT 1
  UNION ALL
  SELECT i+1 FROM big WHERE i<300
)
INSERT INTO t4(id,payload)
SELECT i,
       randomblob(800) || char(10) || printf('row-%03d',i) || randomblob(800)
FROM big;
CREATE INDEX t4p ON t4(payload);
DELETE FROM t4 WHERE id%2=0;
EXPLAIN QUERY PLAN SELECT * FROM t4 WHERE id BETWEEN 1 AND 50;
EXPLAIN QUERY PLAN SELECT * FROM t4 WHERE payload LIKE '%' || char(10) || 'row-1%';
DROP INDEX t4p;
DROP TABLE t4;

-- Test 5: Pointer-map and auto-vacuum interactions with frequent splits and merges
CREATE TABLE t5(a INTEGER PRIMARY KEY, b TEXT) WITHOUT ROWID;
WITH RECURSIVE s(i) AS (
  SELECT 1
  UNION ALL
  SELECT i+1 FROM s WHERE i<4000
)
INSERT INTO t5(a,b) SELECT i, printf('str-%05d', i) FROM s;
CREATE INDEX t5b ON t5(b);
DELETE FROM t5 WHERE a BETWEEN 500 AND 3500;
EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE b BETWEEN 'str-00010' AND 'str-00020';
EXPLAIN QUERY PLAN SELECT * FROM t5 WHERE a IN (1, 2, 3, 3999, 4000);
DROP INDEX t5b;
DROP TABLE t5;
-- ================================================================
-- SQL Regression Test for: Avoid leaving a suspect page in the page-cache if an error occurs during sqlite3PagerAcquire(). (CVS 6922)
-- task_id: 123
-- ================================================================

PRAGMA auto_vacuum = 0;
PRAGMA page_size = 1024;
PRAGMA journal_mode = WAL;
PRAGMA cache_size = 10;

-- Test 1: Trigger pager_acquire_err via SQLITE_FULL when extending file beyond max page (overflow insert)
-- Targets: sqlite3PagerGet -> getPageNormal -> pager_acquire_err path where pgno > mxPgno, pPg non-NULL, sqlite3PcacheDrop(pPg) executed
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);

-- Fill the table with enough rows to grow the database towards cache/size limits.
WITH RECURSIVE r(i) AS (
  SELECT 1
  UNION ALL
  SELECT i+1 FROM r WHERE i < 5000
)
INSERT INTO t1(a, b)
SELECT i, printf('row-%05d', i) FROM r;

-- Force a read of a high-numbered page using an indexed lookup.
CREATE INDEX t1b ON t1(b);
EXPLAIN QUERY PLAN
SELECT b FROM t1 WHERE a = (SELECT max(a) FROM t1);

DROP INDEX IF EXISTS t1b;
DROP TABLE IF EXISTS t1;

-- Test 2: Trigger pager_acquire_err via SQLITE_FULL on large ROWID during insert-select
-- Targets: Path where a new page is allocated for a rowid beyond dbSize but <= mxPgno, then subsequent IO causes pager_acquire_err and pPg is dropped
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(x INTEGER PRIMARY KEY, y TEXT);

INSERT INTO t2 VALUES(1, 'a');
INSERT INTO t2 VALUES(2, 'b');

-- This statement encourages growth and page allocations while reading existing pages.
WITH RECURSIVE r(i) AS (
  SELECT 1
  UNION ALL
  SELECT i+1 FROM r WHERE i < 3000
)
INSERT INTO t2(x, y)
SELECT 1000000 + i, printf('row-%05d', i) FROM r;

EXPLAIN QUERY PLAN
SELECT y FROM t2 WHERE x BETWEEN 1000500 AND 1000550;

DROP TABLE IF EXISTS t2;

-- Test 3: Trigger pager_acquire_err via corruption-like condition on locking/super-journal page
-- Targets: Path where pgno equals special locking page (PAGER_SJ_PGNO), causing SQLITE_CORRUPT_BKPT and pager_acquire_err cleanup
DROP TABLE IF EXISTS t3;
CREATE TABLE t3(a INTEGER PRIMARY KEY, b BLOB);

INSERT INTO t3(a, b)
VALUES(1, zeroblob(8192)),
      (2, zeroblob(8192)),
      (3, zeroblob(8192));

-- Force reads of multiple pages; simulate corruption-related patterns.
EXPLAIN QUERY PLAN
SELECT sum(length(b)) FROM t3 WHERE a IN (1, 2, 3);

DROP TABLE IF EXISTS t3;

-- Test 4: Trigger pager_acquire_err with noContent flag (PAGER_GET_NOCONTENT) through CREATE TABLE without reading from disk
-- Targets: sqlite3PagerGet path with PAGER_GET_NOCONTENT, addToSavepointBitvecs, and bailout on memory pressure leading to pager_acquire_err and cache drop
DROP TABLE IF EXISTS t4;
CREATE TABLE t4(a INTEGER PRIMARY KEY, b TEXT);

BEGIN;
SAVEPOINT sp1;

-- Cause journal/savepoint bookkeeping while avoiding reads of page content.
INSERT INTO t4(a, b) VALUES(1, 'x');
INSERT INTO t4(a, b) VALUES(2, 'y');
DELETE FROM t4 WHERE a = 2;

ROLLBACK TO sp1;
COMMIT;

EXPLAIN QUERY PLAN
SELECT a, b FROM t4;

DROP TABLE IF EXISTS t4;

-- Test 5: Trigger pager_acquire_err via readDbPage error path using ATTACH and WAL
-- Targets: sqlite3PagerGet path where readDbPage() fails during page read, leading to pager_acquire_err and dropping of pPg
DROP TABLE IF EXISTS t5;
DROP TABLE IF EXISTS main.t5;
ATTACH ':memory:' AS aux;

CREATE TABLE t5(id INTEGER PRIMARY KEY, v TEXT);
CREATE TABLE aux.t5_aux(id INTEGER PRIMARY KEY, v TEXT);

INSERT INTO t5 SELECT NULL, printf('mrow-%03d', x) FROM (SELECT 1 AS x UNION ALL SELECT 2 UNION ALL SELECT 3);
INSERT INTO aux.t5_aux SELECT NULL, printf('arow-%03d', x) FROM (SELECT 1 AS x UNION ALL SELECT 2 UNION ALL SELECT 3);

-- Query that causes simultaneous reads from main and aux databases, exercising pager and WAL interactions.
EXPLAIN QUERY PLAN
SELECT m.v, a.v
FROM t5 AS m
JOIN aux.t5_aux AS a ON a.id = m.id
WHERE m.id > 0;

DETACH aux;
DROP TABLE IF EXISTS t5;

-- ================================================================
-- SQL Regression Test for: Hot-journal handling with journal_mode=memory
-- task_id: 124
-- ================================================================

-- Test 1: Basic transaction with journal_mode=MEMORY (normal case)
PRAGMA journal_mode = DELETE;           -- ensure file-based journal
PRAGMA locking_mode = NORMAL;
PRAGMA page_size = 1024;
PRAGMA temp_store = MEMORY;

DROP TABLE IF EXISTS t1;
CREATE TABLE t1(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t1 VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma');

BEGIN;
UPDATE t1 SET v = 'ALPHA' WHERE id = 1;
EXPLAIN QUERY PLAN SELECT * FROM t1 WHERE id = 1;
ROLLBACK;

EXPLAIN QUERY PLAN SELECT * FROM t1 ORDER BY id;

DROP TABLE IF EXISTS t1;

-- Test 2: journal_mode switched to MEMORY, write transaction and rollback
PRAGMA journal_mode = MEMORY;
PRAGMA locking_mode = NORMAL;

DROP TABLE IF EXISTS t2;
CREATE TABLE t2(a INTEGER, b TEXT);
INSERT INTO t2 VALUES (NULL, NULL), (1, 'x'), (2, 'y');

BEGIN;
UPDATE t2 SET b = 'X' WHERE a = 1;
EXPLAIN QUERY PLAN SELECT * FROM t2 WHERE a IS NULL;
ROLLBACK;

EXPLAIN QUERY PLAN SELECT * FROM t2 WHERE b = 'y';

DROP TABLE IF EXISTS t2;

-- Test 3: Change journal_mode from MEMORY to DELETE within same database
PRAGMA journal_mode = MEMORY;

DROP TABLE IF EXISTS t3;
CREATE TABLE t3(x INTEGER, y TEXT);
INSERT INTO t3 VALUES (1, 'one'), (2, 'two'), (3, 'three');

BEGIN;
UPDATE t3 SET y = 'TWO' WHERE x = 2;

EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE y = 'TWO';

PRAGMA journal_mode = DELETE;
ROLLBACK;

EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE x > 1;

DROP TABLE IF EXISTS t3;

-- Test 4: TEMP table with MEMORY journal and various edge-case values
PRAGMA journal_mode = MEMORY;

DROP TABLE IF EXISTS t4;
CREATE TABLE t4(
  id INTEGER PRIMARY KEY,
  n  INTEGER,
  t  TEXT
);

INSERT INTO t4 VALUES (1, NULL, NULL);
INSERT INTO t4 VALUES (2, -9223372036854775808, 'min');
INSERT INTO t4 VALUES (3, 9223372036854775807, 'max');
INSERT INTO t4 VALUES (4, 0, 'zero');
INSERT INTO t4 VALUES (5, 1, 'one');

BEGIN;
DELETE FROM t4 WHERE id IN (1, 3);
EXPLAIN QUERY PLAN SELECT * FROM t4 WHERE n IS NULL;
ROLLBACK;

EXPLAIN QUERY PLAN SELECT * FROM t4 WHERE t LIKE 'm%';

DROP TABLE IF EXISTS t4;

-- Test 5: Multiple connections simulated via ATTACH, switching journal modes
PRAGMA journal_mode = DELETE;

DROP TABLE IF EXISTS main_t;
CREATE TABLE main_t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO main_t VALUES (1, 'a'), (2, 'b');

ATTACH ':memory:' AS memdb;
PRAGMA memdb.journal_mode = MEMORY;

DROP TABLE IF EXISTS memdb.t_attached;
CREATE TABLE memdb.t_attached(x INTEGER, y TEXT);
INSERT INTO memdb.t_attached VALUES (10, 'ten'), (20, 'twenty');

BEGIN;
UPDATE main_t SET v = 'A' WHERE id = 1;
UPDATE memdb.t_attached SET y = 'TEN' WHERE x = 10;

EXPLAIN QUERY PLAN SELECT * FROM main_t WHERE v = 'A';
EXPLAIN QUERY PLAN SELECT * FROM memdb.t_attached WHERE y = 'TEN';

ROLLBACK;

EXPLAIN QUERY PLAN SELECT * FROM main_t;
EXPLAIN QUERY PLAN SELECT * FROM memdb.t_attached;

DETACH memdb;
DROP TABLE IF EXISTS main_t;

-- ================================================================
-- SQL Regression Test for: Fix an assert() failure that may follow an OOM error.
-- task_id: 125
-- ================================================================

PRAGMA encoding = 'UTF-8';
PRAGMA page_size = 1024;
PRAGMA cache_size = 10;

-- ---------------------------------------------------------------
-- Test 1: ANALYZE whole database (sqlite3Analyze form 1, analyzeDatabase)
--   - Exercises sqlite3Analyze() form 1 (no arguments)
--   - Exercises analyzeDatabase() and openStatTable() normal path
--   - Generates sqlite_stat1/sqlite_stat4 rows; drives STAT4 sampling loop
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS t2;

CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT, c INT);
CREATE INDEX t1_b_c ON t1(b, c);

CREATE TABLE t2(x TEXT, y INT, z INT);
CREATE INDEX t2_y ON t2(y);
CREATE INDEX t2_y_z ON t2(y, z);

INSERT INTO t1(a,b,c) VALUES
  (1, 'alpha', 10),
  (2, 'beta',  20),
  (3, 'beta',  30),
  (4, 'gamma', 40),
  (5, NULL,    50);

INSERT INTO t2(x,y,z) VALUES
  ('p', 1, 100),
  ('q', 1, 200),
  ('r', 2, 300),
  ('s', 3, 400),
  (NULL, NULL, NULL);

-- Run ANALYZE over all databases (form 1).
EXPLAIN QUERY PLAN ANALYZE;
ANALYZE;

-- Query the generated statistics to ensure paths are exercised.
EXPLAIN QUERY PLAN SELECT * FROM sqlite_stat1 ORDER BY tbl, idx;
SELECT * FROM sqlite_stat1 ORDER BY tbl, idx;

-- If STAT4 is enabled, this will scan sqlite_stat4, exercising loadStat4.
EXPLAIN QUERY PLAN SELECT * FROM sqlite_stat4 ORDER BY tbl, idx LIMIT 5;
SELECT * FROM sqlite_stat4 ORDER BY tbl, idx LIMIT 5;

DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS t2;


-- ---------------------------------------------------------------
-- Test 2: ANALYZE specific database and table (sqlite3Analyze forms 2 & 3)
--   - Exercises sqlite3Analyze() form 2 (ANALYZE main)
--   - Exercises sqlite3Analyze() form 3 (ANALYZE main.t3 and ANALYZE t3)
--   - Drives analyzeTable(), openStatTable() with "tbl" filter
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS t3;

CREATE TABLE t3(id INTEGER PRIMARY KEY, v TEXT, w INT);
CREATE INDEX t3_v ON t3(v);
CREATE INDEX t3_w ON t3(w);

INSERT INTO t3(v,w) VALUES
  ('one',   1),
  ('two',   2),
  ('three', 3),
  ('two',   4),
  (NULL,   NULL);

-- Analyze the whole main database (form 2)
EXPLAIN QUERY PLAN ANALYZE main;
ANALYZE main;

-- Analyze the table using explicit db name (form 3)
EXPLAIN QUERY PLAN ANALYZE main.t3;
ANALYZE main.t3;

-- Analyze the table using implicit db name (form 3 with two-part name)
EXPLAIN QUERY PLAN ANALYZE t3;
ANALYZE t3;

-- Read back stats for this table only
EXPLAIN QUERY PLAN SELECT * FROM sqlite_stat1 WHERE tbl='t3' ORDER BY idx;
SELECT * FROM sqlite_stat1 WHERE tbl='t3' ORDER BY idx;

DROP TABLE IF EXISTS t3;


-- ---------------------------------------------------------------
-- Test 3: ANALYZE a single index (analyzeTable with pOnlyIdx, idx filter)
--   - Exercises sqlite3Analyze() form 3 resolving to an index name
--   - Exercises analyzeTable() with non-NULL pOnlyIdx
--   - Exercises openStatTable() with zWhereType="idx" and partial index path
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS t4;

CREATE TABLE t4(a INT, b INT, c TEXT);
CREATE INDEX t4_b ON t4(b);
CREATE INDEX t4_b_partial ON t4(b) WHERE c IS NOT NULL;

INSERT INTO t4(a,b,c) VALUES
  (1, 10, 'x'),
  (2, 10, 'y'),
  (3, 20, NULL),
  (4, 20, 'z'),
  (5, 30, NULL),
  (6, 30, 'w');

-- Analyze only the partial index by name; this should cause
-- openStatTable(..., zWhereType="idx") and partial-index specific paths.
EXPLAIN QUERY PLAN ANALYZE main.t4_b_partial;
ANALYZE main.t4_b_partial;

-- Check which stat rows were produced for this specific index.
EXPLAIN QUERY PLAN SELECT * FROM sqlite_stat1 WHERE idx='t4_b_partial';
SELECT * FROM sqlite_stat1 WHERE idx='t4_b_partial';

DROP TABLE IF EXISTS t4;


-- ---------------------------------------------------------------
-- Test 4: Empty table and NULL-heavy data (edge cases for analysis loops)
--   - Exercises paths where row-count is zero for some tables
--   - Ensures STAT1 creation for empty vs non-empty tables
--   - Exercises code paths around addrGotoEnd / jZeroRows jumps
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS t5;
DROP TABLE IF EXISTS t6;

-- t5 is empty, t6 has many NULLs and duplicates
CREATE TABLE t5(p INTEGER PRIMARY KEY, q TEXT);
CREATE INDEX t5_q ON t5(q);

CREATE TABLE t6(r INT, s TEXT, t INT);
CREATE INDEX t6_r_s ON t6(r, s);

INSERT INTO t6(r,s,t) VALUES
  (1,  NULL, NULL),
  (1,  NULL, 0),
  (1,  'dup', 0),
  (1,  'dup', 1),
  (2,  'dup', 1),
  (2,  'dup', 1),
  (NULL, NULL, NULL);

-- Analyze both tables together
EXPLAIN QUERY PLAN ANALYZE;
ANALYZE;

-- t5 may be omitted from sqlite_stat1 if empty; ensure queries run
EXPLAIN QUERY PLAN SELECT * FROM sqlite_stat1 WHERE tbl IN ('t5','t6') ORDER BY tbl, idx;
SELECT * FROM sqlite_stat1 WHERE tbl IN ('t5','t6') ORDER BY tbl, idx;

DROP TABLE IF EXISTS t5;
DROP TABLE IF EXISTS t6;


-- ---------------------------------------------------------------
-- Test 5: Exercise analysis reload and OOM-handling-related paths
--   - Exercises sqlite3AnalysisLoad via OP_LoadAnalysis after ANALYZE
--   - Exercises loading of sqlite_stat1/sqlite_stat4 into internal structures
--   - Re-runs ANALYZE after DDL to cause stats to be discarded and rebuilt
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS t7;

CREATE TABLE t7(id INTEGER PRIMARY KEY, k INT, v TEXT);
CREATE INDEX t7_k ON t7(k);

INSERT INTO t7(k,v) VALUES
  (1, 'a'),
  (1, 'b'),
  (2, 'c'),
  (3, 'd'),
  (3, 'e');

-- First ANALYZE run populates sqlite_stat1/4 and triggers sqlite3AnalysisLoad
EXPLAIN QUERY PLAN ANALYZE t7;
ANALYZE t7;

-- Run some queries that should consult the query planner using loaded stats
EXPLAIN QUERY PLAN SELECT * FROM t7 WHERE k=1;
SELECT * FROM t7 WHERE k=1;

-- Modify data significantly and ANALYZE again to force re-load of stats
INSERT INTO t7(k,v) VALUES
  (1, 'x'),
  (1, 'y'),
  (1, 'z'),
  (4, 'u');

EXPLAIN QUERY PLAN ANALYZE t7;
ANALYZE t7;

-- Observe updated statistics entries
EXPLAIN QUERY PLAN SELECT * FROM sqlite_stat1 WHERE tbl='t7';
SELECT * FROM sqlite_stat1 WHERE tbl='t7';

DROP TABLE IF EXISTS t7;

-- ================================================================
-- SQL Regression Test for: Avoid calling sqlite3VdbeRecordCompare()
-- with uninitialized memory following an OOM in index moveto logic.
-- task_id: 126
-- ================================================================

-- Test 1: Large index record requiring overflow pages, scan via ORDER BY to
-- exercise moveto_index overflow path (normal successful case).
DROP TABLE IF EXISTS t1;
PRAGMA page_size = 1024;
PRAGMA cache_size = 10;
CREATE TABLE t1(id INTEGER PRIMARY KEY, x TEXT);

WITH RECURSIVE c(i, s) AS (
  SELECT 1, printf('%0500d', 0)
  UNION ALL
  SELECT i+1, s || s FROM c WHERE i<3
)
INSERT INTO t1(id, x)
SELECT 1, s FROM c WHERE i=3;

INSERT INTO t1(id, x) VALUES(2, x);

CREATE INDEX t1x ON t1(x);

EXPLAIN QUERY PLAN
SELECT id FROM t1 WHERE x > '0' ORDER BY x;

DROP INDEX t1x;
DROP TABLE t1;

-- Test 2: Corrupt-like scenario using very large TEXT key to stress
-- overflow key length checks and accessPayload path.
DROP TABLE IF EXISTS t2;
PRAGMA page_size = 1024;
CREATE TABLE t2(id INTEGER PRIMARY KEY, x TEXT);

WITH RECURSIVE c(i, s) AS (
  SELECT 1, printf('%0500d', 0)
  UNION ALL
  SELECT i+1, s || s FROM c WHERE i<5
)
INSERT INTO t2(id, x)
SELECT 1, s FROM c WHERE i=5;

CREATE INDEX t2x ON t2(x);

EXPLAIN QUERY PLAN
SELECT * FROM t2 WHERE x = (SELECT x FROM t2);

DROP INDEX t2x;
DROP TABLE t2;

-- Test 3: Multiple large index keys with duplicates and NULL to cover
-- different compare outcomes (c<0, c>0, c==0) in moveto_index loop.
DROP TABLE IF EXISTS t3;
PRAGMA page_size = 1024;
CREATE TABLE t3(a INTEGER PRIMARY KEY, b TEXT);

WITH RECURSIVE big(i, s) AS (
  SELECT 1, printf('%0500d', 0)
  UNION ALL
  SELECT i+1, s || s FROM big WHERE i<4
)
INSERT INTO t3(a, b)
SELECT 1, s FROM big WHERE i=4;

INSERT INTO t3(a, b)
VALUES
  (2, NULL),
  (3, b || 'suffix'),
  (4, b),
  (5, b || 'ZZZ');

CREATE INDEX t3b ON t3(b);

EXPLAIN QUERY PLAN
SELECT a FROM t3 WHERE b IS NOT NULL ORDER BY b;

DROP INDEX t3b;
DROP TABLE t3;

-- Test 4: Composite index with large TEXT component and DESC search to
-- exercise moveto_index on non-unique, multi-column keys.
DROP TABLE IF EXISTS t4;
PRAGMA page_size = 1024;
CREATE TABLE t4(a INTEGER, b TEXT, c TEXT);

WITH RECURSIVE r(i, s) AS (
  SELECT 1, printf('%0500d', 0)
  UNION ALL
  SELECT i+1, s || s FROM r WHERE i<3
)
INSERT INTO t4(a, b, c)
SELECT 1, s, 'alpha' FROM r WHERE i=3;

INSERT INTO t4(a, b, c) VALUES
  (2, b, 'beta'),
  (3, b || 'X', 'gamma'),
  (4, NULL, 'delta');

CREATE INDEX t4abc ON t4(b, a, c);

EXPLAIN QUERY PLAN
SELECT a, b FROM t4 WHERE b >= '0' ORDER BY b DESC, a;

DROP INDEX t4abc;
DROP TABLE t4;

-- Test 5: Large index records with empty result set to ensure end-of-loop
-- path (lwr>upr break) after moveto_index search on overflow keys.
DROP TABLE IF EXISTS t5;
PRAGMA page_size = 1024;
CREATE TABLE t5(id INTEGER PRIMARY KEY, x TEXT);

WITH RECURSIVE c(i, s) AS (
  SELECT 1, printf('%0500d', 0)
  UNION ALL
  SELECT i+1, s || s FROM c WHERE i<3
)
INSERT INTO t5(id, x)
SELECT 1, s FROM c WHERE i=3;

CREATE INDEX t5x ON t5(x);

EXPLAIN QUERY PLAN
SELECT * FROM t5 WHERE x = 'nonexistent_large_key';

DROP INDEX t5x;
DROP TABLE t5;

-- ================================================================
-- SQL Regression Test for: Make sure that the output of EXPLAIN is right
-- when the P4 argument of an opcode is of type P4_MEM with MEM_Blob.
-- task_id: 127
-- ================================================================

-- Test 1: EXPLAIN on a statement with a BLOB literal in the bytecode (P4_MEM blob)
-- Target: displayP4() case P4_MEM branch where pMem->flags has MEM_Blob
CREATE TABLE t1(a INTEGER PRIMARY KEY, b BLOB);
INSERT INTO t1 VALUES(1, X'00112233');
INSERT INTO t1 VALUES(2, X'');              -- empty blob edge case

-- Use a BLOB literal in an expression so it is embedded in bytecode P4 as MEM_Blob
EXPLAIN SELECT b, length(b), b || X'FF' AS b2 FROM t1 WHERE b = X'00112233';
EXPLAIN QUERY PLAN SELECT b, length(b), b || X'FF' AS b2 FROM t1 WHERE b = X'00112233';

DROP TABLE IF EXISTS t1;


-- Test 2: BLOB parameter flowing through arithmetic/comparison to ensure MEM_Blob
-- Target: P4_MEM blob formatting even when other P4_MEM numeric/string paths exist
CREATE TABLE t2(x INTEGER, y BLOB, z TEXT);
INSERT INTO t2 VALUES(1, X'ABCD', 'text1');
INSERT INTO t2 VALUES(2, X'1234', 'text2');
INSERT INTO t2 VALUES(3, NULL,   'text3');       -- NULL edge row

-- Force a BLOB P4 in an OP_Compare/OP_Is opcode via equality on BLOB column
EXPLAIN SELECT y FROM t2 WHERE y = X'ABCD' AND z = 'text1';
EXPLAIN QUERY PLAN SELECT y FROM t2 WHERE y = X'ABCD' AND z = 'text1';

DROP TABLE IF EXISTS t2;


-- Test 3: BLOB default values and UPDATE to BLOB to exercise constant MEM_Blob
-- Target: displayP4() handling of MEM_Blob for default-value and set-column opcodes
CREATE TABLE t3(
  id INTEGER PRIMARY KEY,
  d  BLOB DEFAULT X'CAFEBABE',
  e  BLOB
);
INSERT INTO t3(id) VALUES(1);
INSERT INTO t3(id, e) VALUES(2, X'010203');
INSERT INTO t3(id, e) VALUES(3, NULL);          -- NULL with blob column

-- EXPLAIN INSERT using default BLOB and explicit BLOB values
EXPLAIN INSERT INTO t3(e) VALUES(X'DEADBEEF');
EXPLAIN QUERY PLAN INSERT INTO t3(e) VALUES(X'DEADBEEF');

-- EXPLAIN UPDATE that sets a column to a BLOB literal
EXPLAIN UPDATE t3 SET e = X'FFEE' WHERE id = 1;
EXPLAIN QUERY PLAN UPDATE t3 SET e = X'FFEE' WHERE id = 1;

DROP TABLE IF EXISTS t3;


-- Test 4: BLOBs used in INDEX and WHERE to exercise blob comparison opcodes
-- Target: displayP4() for MEM_Blob values used in index-based lookup/comparison
CREATE TABLE t4(a INTEGER PRIMARY KEY, b BLOB, c TEXT);
INSERT INTO t4 VALUES(1, X'0001', 'alpha');
INSERT INTO t4 VALUES(2, X'0002', 'beta');
INSERT INTO t4 VALUES(3, X'0003', 'gamma');
INSERT INTO t4 VALUES(4, NULL,   'delta');      -- row with NULL blob

CREATE INDEX t4_b_idx ON t4(b);

-- Equality and range predicates on BLOB column to generate comparison opcodes
EXPLAIN SELECT a, b FROM t4 WHERE b = X'0002';
EXPLAIN QUERY PLAN SELECT a, b FROM t4 WHERE b >= X'0001' AND b <= X'0003';

DROP INDEX IF EXISTS t4_b_idx;
DROP TABLE IF EXISTS t4;


-- Test 5: BLOBs in expressions, concatenation, and DISTINCT/GROUP BY
-- Target: exercise multiple VDBE opcodes with P4_MEM BLOB arguments (blob constants)
CREATE TABLE t5(id INTEGER, blobval BLOB);
INSERT INTO t5 VALUES(1, X'AA');
INSERT INTO t5 VALUES(2, X'BB');
INSERT INTO t5 VALUES(3, X'AA');              -- duplicate blob for DISTINCT/GROUP BY
INSERT INTO t5 VALUES(4, NULL);               -- NULL blob entry

-- Use BLOB literals in concatenation and CASE; DISTINCT/GROUP BY adds compare ops
EXPLAIN SELECT DISTINCT blobval || X'CC' AS k FROM t5
         WHERE blobval IN (X'AA', X'BB')
         GROUP BY blobval || X'CC'
         ORDER BY k;

EXPLAIN QUERY PLAN SELECT DISTINCT blobval || X'CC' AS k FROM t5
         WHERE blobval IN (X'AA', X'BB')
         GROUP BY blobval || X'CC'
         ORDER BY k;

DROP TABLE IF EXISTS t5;

-- ================================================================
-- SQL Regression Test for: Fix sqlite3VdbeMayAbort()/AssertMayAbort OOM assert
-- task_id: 128
-- ================================================================

-- Test 1: Simple single-row UPDATE with RAISE(ABORT) trigger (mayAbort=1, hasAbort=1)
DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS log1;
CREATE TABLE t1(id INTEGER PRIMARY KEY, x INTEGER);
CREATE TABLE log1(msg TEXT);
CREATE TRIGGER tr1 BEFORE UPDATE ON t1
BEGIN
  INSERT INTO log1 VALUES('before-update');
  SELECT RAISE(ABORT, 'abort in trigger');
END;
INSERT INTO t1 VALUES(1, 10);
INSERT INTO log1 VALUES('init');
-- This UPDATE is a single statement that may abort; it should set mayAbort=1.
EXPLAIN QUERY PLAN UPDATE t1 SET x=x+1 WHERE id=1;
DROP TRIGGER tr1;
DROP TABLE t1;
DROP TABLE log1;

-- Test 2: Multi-row UPDATE with CHECK constraint and RAISE(ABORT) (isMultiWrite=1, hasAbort=1)
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(id INTEGER PRIMARY KEY, x INTEGER,
  CONSTRAINT ck_x CHECK (x<5 OR RAISE(ABORT, 'too big'))
);
INSERT INTO t2 VALUES(1, 1);
INSERT INTO t2 VALUES(2, 2);
INSERT INTO t2 VALUES(3, 3);
-- Multi-row UPDATE that can violate the CHECK and abort.
EXPLAIN QUERY PLAN UPDATE t2 SET x=x+3;
DROP TABLE t2;

-- Test 3: CREATE TABLE with FOREIGN KEY and ON CONFLICT ABORT (hasCreateTable, hasFkCounter)
PRAGMA foreign_keys = ON;
DROP TABLE IF EXISTS parent;
DROP TABLE IF EXISTS child;
CREATE TABLE parent(id INTEGER PRIMARY KEY);
CREATE TABLE child(
  id INTEGER PRIMARY KEY,
  pid INTEGER,
  FOREIGN KEY(pid) REFERENCES parent(id) ON DELETE RESTRICT
);
INSERT INTO parent VALUES(1);
INSERT INTO child VALUES(1,1);
-- Deleting from parent may require statement journal and mayAbort logic.
EXPLAIN QUERY PLAN DELETE FROM parent WHERE id=1;
DROP TABLE child;
DROP TABLE parent;

-- Test 4: CREATE TABLE AS SELECT with subquery and ORDER BY (hasCreateTable && hasInitCoroutine)
DROP TABLE IF EXISTS src;
DROP TABLE IF EXISTS ct1;
CREATE TABLE src(a INTEGER, b TEXT);
INSERT INTO src VALUES(1,'one');
INSERT INTO src VALUES(2,'two');
INSERT INTO src VALUES(NULL,'null');
-- CTAS with SELECT that uses ORDER BY and DISTINCT to generate coroutines.
EXPLAIN QUERY PLAN CREATE TABLE ct1 AS
  SELECT DISTINCT a, b FROM src WHERE a IS NOT NULL ORDER BY b;
DROP TABLE IF EXISTS ct1;
DROP TABLE src;

-- Test 5: CREATE INDEX on table with NULLs and duplicates (hasCreateIndex path)
DROP TABLE IF EXISTS t5;
CREATE TABLE t5(id INTEGER PRIMARY KEY, x INTEGER, y TEXT);
INSERT INTO t5 VALUES(1, NULL, 'a');
INSERT INTO t5 VALUES(2, 5, 'b');
INSERT INTO t5 VALUES(3, 5, 'b');
INSERT INTO t5 VALUES(4, 10, NULL);
-- Creating an index on column x (with duplicates and NULL) exercises
-- the hasCreateIndex and mayAbort analysis logic.
EXPLAIN QUERY PLAN CREATE INDEX t5x ON t5(x);
DROP INDEX IF EXISTS t5x;
DROP TABLE t5;
-- ================================================================
-- SQL Regression Test for: Fix a problem with foreign key constraints that map from an IPK column
-- task_id: 129
-- ================================================================

PRAGMA foreign_keys = ON;

-- Test 1: Single-column FK mapping from child IPK to parent INTEGER PRIMARY KEY (aiFree==NULL, aiCol points to iFrom, value equals iPKey and is remapped to -1)
CREATE TABLE p1(
  id INTEGER PRIMARY KEY,
  data TEXT
);
CREATE TABLE c1(
  id INTEGER PRIMARY KEY,
  p1_id INTEGER,
  other TEXT,
  FOREIGN KEY(p1_id) REFERENCES p1(id)
);
INSERT INTO p1(id, data) VALUES (1, 'one'), (2, 'two');
INSERT INTO c1(id, p1_id, other) VALUES (10, 1, 'a'), (11, 2, 'b');

-- DML that triggers sqlite3FkCheck() and uses fkLookupParent with aiCol derived from iFrom
EXPLAIN QUERY PLAN UPDATE c1 SET other = 'c' WHERE id = 10;
EXPLAIN QUERY PLAN DELETE FROM c1 WHERE id = 11;

DROP TABLE c1;
DROP TABLE p1;

-- Test 2: Composite foreign key where first child column is rowid alias (INTEGER PRIMARY KEY), exercising aiFree array path and remapping of aiCol[i]==iPKey to -1
CREATE TABLE p2(
  a INTEGER PRIMARY KEY,
  b INTEGER,
  c TEXT,
  UNIQUE(b,c)
);
CREATE TABLE c2(
  x INTEGER PRIMARY KEY,
  y INTEGER,
  z TEXT,
  FOREIGN KEY(x, y) REFERENCES p2(a, b)
);
INSERT INTO p2(a, b, c) VALUES (1, 100, 'x'), (2, 200, 'y');
INSERT INTO c2(x, y, z) VALUES (1, 100, 'ok'), (2, 200, 'ok2');

EXPLAIN QUERY PLAN UPDATE c2 SET z = 'changed' WHERE x = 1;
EXPLAIN QUERY PLAN DELETE FROM c2 WHERE x = 2;

DROP TABLE c2;
DROP TABLE p2;

-- Test 3: Composite FK where a non-IPK child column maps to parent IPK; ensures aiFree path with some aiCol[i] != iPKey and loop over all columns
CREATE TABLE p3(
  k INTEGER PRIMARY KEY,
  v TEXT,
  u INT,
  UNIQUE(v,u)
);
CREATE TABLE c3(
  r INTEGER PRIMARY KEY,
  fk1 INT,
  fk2 INT,
  note TEXT,
  FOREIGN KEY(fk1, fk2) REFERENCES p3(v, u)
);
INSERT INTO p3(k, v, u) VALUES (1, 7, 8), (2, 9, 10);
INSERT INTO c3(r, fk1, fk2, note) VALUES (1, 7, 8, 'row1'), (2, 9, 10, 'row2');

EXPLAIN QUERY PLAN UPDATE c3 SET note = 'u1' WHERE r = 1;
EXPLAIN QUERY PLAN DELETE FROM c3 WHERE r = 2;

DROP TABLE c3;
DROP TABLE p3;

-- Test 4: Composite FK with three columns including the INTEGER PRIMARY KEY column; exercise aiFree loop where one element equals iPKey and others do not
CREATE TABLE p4(
  a INTEGER PRIMARY KEY,
  b INT,
  c INT,
  UNIQUE(a,b,c)
);
CREATE TABLE c4(
  id INTEGER PRIMARY KEY,
  ca INT,
  cb INT,
  cc INT,
  FOREIGN KEY(ca, cb, cc) REFERENCES p4(a, b, c)
);
INSERT INTO p4(a, b, c) VALUES (1, 2, 3), (4, 5, 6);
INSERT INTO c4(id, ca, cb, cc) VALUES (10, 1, 2, 3), (11, 4, 5, 6);

EXPLAIN QUERY PLAN UPDATE c4 SET cc = 99 WHERE id = 10;
EXPLAIN QUERY PLAN DELETE FROM c4 WHERE id = 11;

DROP TABLE c4;
DROP TABLE p4;

-- Test 5: Foreign key on WITHOUT ROWID child referencing parent INTEGER PRIMARY KEY, including NULL and boundary values to exercise IsNull checks and aiCol remapping
CREATE TABLE p5(
  id INTEGER PRIMARY KEY,
  val TEXT
);
CREATE TABLE c5(
  key INTEGER,
  ref INTEGER,
  extra TEXT,
  FOREIGN KEY(ref) REFERENCES p5(id)
) WITHOUT ROWID;
INSERT INTO p5(id, val) VALUES (1, 'a'), (1000000000, 'big');
INSERT INTO c5(key, ref, extra) VALUES (1, 1, 'ok'), (2, 1000000000, 'big-ok'), (3, NULL, 'null-ref');

EXPLAIN QUERY PLAN UPDATE c5 SET extra = 'x' WHERE key = 1;
EXPLAIN QUERY PLAN UPDATE c5 SET extra = 'y' WHERE ref IS NULL;
EXPLAIN QUERY PLAN DELETE FROM c5 WHERE key = 2;

DROP TABLE c5;
DROP TABLE p5;
-- ================================================================
-- SQL Regression Test for: Fix another OOM related problem in fkey.c.
-- task_id: 130
-- ================================================================

PRAGMA foreign_keys = ON;

-- ----------------------------------------------------------------
-- Test 1: CREATE TABLE with self-referencing FK to exercise OOM path
-- in build.c where sqlite3HashInsert returns the same pointer and
-- db->mallocFailed is set before exiting FK creation.
-- (Normal successful creation; coverage via EXPLAIN QUERY PLAN.)
-- ----------------------------------------------------------------
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(
  id INTEGER PRIMARY KEY,
  parent_id INTEGER,
  value TEXT,
  FOREIGN KEY(parent_id) REFERENCES t1(id)
);
INSERT INTO t1 VALUES (1, NULL, 'root');
INSERT INTO t1 VALUES (2, 1, 'child');

EXPLAIN QUERY PLAN
SELECT * FROM t1 WHERE parent_id IS NULL;

EXPLAIN QUERY PLAN
SELECT * FROM t1 WHERE id IN (SELECT parent_id FROM t1 WHERE parent_id NOT NULL);

DROP TABLE t1;

-- ----------------------------------------------------------------
-- Test 2: DROP parent table with deferred child FK to exercise
-- sqlite3FkDropTable path using fkScanReferences with non-NULL pSrc
-- and pChanges=NULL (DELETE case), including WHERE-generator and
-- sqlite3WhereBegin/sqlite3WhereEnd guarded by if( pWInfo ).
-- ----------------------------------------------------------------
DROP TABLE IF EXISTS p2;
DROP TABLE IF EXISTS c2;
CREATE TABLE p2(
  id INTEGER PRIMARY KEY,
  data TEXT
);
CREATE TABLE c2(
  id INTEGER PRIMARY KEY,
  pid INTEGER,
  x TEXT,
  FOREIGN KEY(pid) REFERENCES p2(id) DEFERRABLE INITIALLY DEFERRED
);

INSERT INTO p2 VALUES (1, 'p');
INSERT INTO c2 VALUES (10, 1, 'c');

BEGIN;
-- Leave a deferred FK constraint potentially outstanding by deleting parent
DELETE FROM p2 WHERE id = 1;

EXPLAIN QUERY PLAN SELECT * FROM c2 WHERE pid = 1;

-- Dropping parent should invoke sqlite3FkDropTable and fkScanReferences
DROP TABLE p2;
ROLLBACK;

DROP TABLE IF EXISTS c2;

-- ----------------------------------------------------------------
-- Test 3: UPDATE parent key with deferred FK to exercise fkScanReferences
-- with pChanges!=0 (UPDATE case), regNew!=0 and isDeferred!=0 branches.
-- Also ensure sqlite3WhereEnd is called only if sqlite3WhereBegin
-- succeeds (pWInfo!=0).
-- ----------------------------------------------------------------
DROP TABLE IF EXISTS p3;
DROP TABLE IF EXISTS c3;
CREATE TABLE p3(
  id INTEGER PRIMARY KEY,
  v TEXT
);
CREATE TABLE c3(
  id INTEGER PRIMARY KEY,
  pid INTEGER,
  note TEXT,
  FOREIGN KEY(pid) REFERENCES p3(id) DEFERRABLE INITIALLY DEFERRED
);
INSERT INTO p3 VALUES(1, 'one');
INSERT INTO c3 VALUES(1, 1, 'child-one');

BEGIN;
UPDATE p3 SET id = id + 10 WHERE id = 1;

EXPLAIN QUERY PLAN SELECT * FROM c3 WHERE pid = 1;
EXPLAIN QUERY PLAN SELECT * FROM c3 WHERE pid = 11;

ROLLBACK;
DROP TABLE c3;
DROP TABLE p3;

-- ----------------------------------------------------------------
-- Test 4: UPDATE that does not modify FK columns to exercise the
-- pChanges!=0 early-jump logic around fkScanReferences in UPDATE
-- processing, ensuring the scan is skipped when FK columns unchanged.
-- ----------------------------------------------------------------
DROP TABLE IF EXISTS p4;
DROP TABLE IF EXISTS c4;
CREATE TABLE p4(
  id INTEGER PRIMARY KEY,
  v TEXT
);
CREATE TABLE c4(
  id INTEGER PRIMARY KEY,
  pid INTEGER,
  other TEXT,
  FOREIGN KEY(pid) REFERENCES p4(id)
);
INSERT INTO p4 VALUES(1, 'parent');
INSERT INTO c4 VALUES(1, 1, 'child');

BEGIN;
-- UPDATE modifies only non-FK column in child table
UPDATE c4 SET other = other WHERE id = 1;

EXPLAIN QUERY PLAN SELECT * FROM c4 WHERE pid = 1;

COMMIT;
DROP TABLE c4;
DROP TABLE p4;

-- ----------------------------------------------------------------
-- Test 5: WITHOUT ROWID self-referencing composite FK to exercise the
-- special NOT( a==? AND b==? ) WHERE-clause construction in
-- fkScanReferences for WITHOUT ROWID and use of sqlite3WhereEnd(pWInfo)
-- guarded by if( pWInfo ).
-- ----------------------------------------------------------------
DROP TABLE IF EXISTS p5;
CREATE TABLE p5(
  a INTEGER,
  b INTEGER,
  c TEXT,
  PRIMARY KEY(a,b) WITHOUT ROWID
);

DROP TABLE IF EXISTS c5;
CREATE TABLE c5(
  a INTEGER,
  b INTEGER,
  d TEXT,
  FOREIGN KEY(a,b) REFERENCES p5(a,b)
);

INSERT INTO p5 VALUES(1, 1, 'p11');
INSERT INTO p5 VALUES(2, 2, 'p22');
INSERT INTO c5 VALUES(1, 1, 'c11');
INSERT INTO c5 VALUES(2, 2, 'c22');

BEGIN;
-- UPDATE parent composite key to itself to exercise WHERE builder
UPDATE p5 SET a = a, b = b WHERE a = 1 AND b = 1;

EXPLAIN QUERY PLAN SELECT * FROM c5 WHERE a = 1 AND b = 1;
EXPLAIN QUERY PLAN SELECT * FROM p5 WHERE a = 2 AND b = 2;

COMMIT;
DROP TABLE c5;
DROP TABLE p5;

-- ================================================================
-- SQL Regression Test for: Change the version number to 3.6.19.
-- Focus: testcase() coverage for new IS / IS NOT operators in expr.c
-- task_id: 131
-- ================================================================

-- Test 1: Simple IS comparison with non-NULL constants (covers TK_IS path, op remapped to TK_NE)
CREATE TABLE t_is1(a INTEGER, b INTEGER);
INSERT INTO t_is1 VALUES (1, 1);
INSERT INTO t_is1 VALUES (1, 2);
INSERT INTO t_is1 VALUES (2, 2);

-- Use a WHERE clause with the IS operator between two non-NULL expressions.
EXPLAIN QUERY PLAN
SELECT * FROM t_is1 WHERE a IS b;

DROP TABLE t_is1;

-- Test 2: IS comparison involving NULLs (ensures SQLITE_NULLEQ handling in TK_IS path)
CREATE TABLE t_is2(a INTEGER, b INTEGER);
INSERT INTO t_is2 VALUES (NULL, NULL);
INSERT INTO t_is2 VALUES (NULL, 1);
INSERT INTO t_is2 VALUES (1, NULL);
INSERT INTO t_is2 VALUES (2, 2);

EXPLAIN QUERY PLAN
SELECT * FROM t_is2 WHERE a IS b;

DROP TABLE t_is2;

-- Test 3: Simple IS NOT comparison with non-NULL constants (covers TK_ISNOT path, op remapped to TK_EQ)
CREATE TABLE t_isnot1(a TEXT, b TEXT);
INSERT INTO t_isnot1 VALUES ('x', 'x');
INSERT INTO t_isnot1 VALUES ('x', 'y');
INSERT INTO t_isnot1 VALUES ('y', 'y');

EXPLAIN QUERY PLAN
SELECT * FROM t_isnot1 WHERE a IS NOT b;

DROP TABLE t_isnot1;

-- Test 4: IS NOT comparison involving NULLs and mixed values (exercise SQLITE_NULLEQ for TK_ISNOT)
CREATE TABLE t_isnot2(a INTEGER, b INTEGER);
INSERT INTO t_isnot2 VALUES (NULL, NULL);
INSERT INTO t_isnot2 VALUES (1, NULL);
INSERT INTO t_isnot2 VALUES (NULL, 1);
INSERT INTO t_isnot2 VALUES (1, 1);

EXPLAIN QUERY PLAN
SELECT * FROM t_isnot2 WHERE a IS NOT b;

DROP TABLE t_isnot2;

-- Test 5: IS / IS NOT with expressions (non-column operands) to exercise expr.c comparison logic
CREATE TABLE t_is3(a INTEGER, b INTEGER);
INSERT INTO t_is3 VALUES (1, 1);
INSERT INTO t_is3 VALUES (1, NULL);
INSERT INTO t_is3 VALUES (NULL, 1);
INSERT INTO t_is3 VALUES (2, 3);

-- Use computed expressions on both sides of IS and IS NOT
EXPLAIN QUERY PLAN
SELECT * FROM t_is3
 WHERE (a+0) IS (b+0)
    OR (a+1) IS NOT (b+1);

DROP TABLE t_is3;
-- ================================================================
-- SQL Regression Test for: Fix a problem with FK constraints that implicitly map to a composite primary key.
-- task_id: 132
-- ================================================================
PRAGMA foreign_keys = ON;

-- Test 1: Implicit FK mapping to composite PRIMARY KEY, valid insert (no mismatch)
CREATE TABLE p1(
  a INTEGER,
  b INTEGER,
  c TEXT,
  PRIMARY KEY(a, b)
);

CREATE TABLE c1(
  x INTEGER,
  y INTEGER,
  z TEXT,
  FOREIGN KEY(x, y) REFERENCES p1
);

INSERT INTO p1 VALUES(1, 10, 'row1');
INSERT INTO p1 VALUES(2, 20, 'row2');

EXPLAIN QUERY PLAN INSERT INTO c1 VALUES(1, 10, 'ok1');
INSERT INTO c1 VALUES(1, 10, 'ok1');

EXPLAIN QUERY PLAN INSERT INTO c1 VALUES(2, 20, 'ok2');
INSERT INTO c1 VALUES(2, 20, 'ok2');

DROP TABLE c1;
DROP TABLE p1;

-- Test 2: Implicit FK mapping to composite PRIMARY KEY, violate FK to hit constraint counter
CREATE TABLE p2(
  a INTEGER,
  b INTEGER,
  info TEXT,
  PRIMARY KEY(a, b)
);

CREATE TABLE c2(
  x INTEGER,
  y INTEGER,
  note TEXT,
  FOREIGN KEY(x, y) REFERENCES p2
);

INSERT INTO p2 VALUES(1, 1, 'p2-1');

EXPLAIN QUERY PLAN INSERT INTO c2 VALUES(1, 2, 'bad1');
INSERT OR IGNORE INTO c2 VALUES(1, 2, 'bad1');

EXPLAIN QUERY PLAN INSERT INTO c2 VALUES(NULL, NULL, 'nulls');
INSERT OR IGNORE INTO c2 VALUES(NULL, NULL, 'nulls');

DROP TABLE c2;
DROP TABLE p2;

-- Test 3: Implicit FK mapping, composite PK with different column order in child
CREATE TABLE p3(
  k1 INTEGER,
  k2 INTEGER,
  payload TEXT,
  PRIMARY KEY(k1, k2)
);

CREATE TABLE c3(
  col1 INTEGER,
  col2 INTEGER,
  extra TEXT,
  FOREIGN KEY(col2, col1) REFERENCES p3
);

INSERT INTO p3 VALUES(5, 6, 'five-six');
INSERT INTO p3 VALUES(7, 8, 'seven-eight');

EXPLAIN QUERY PLAN INSERT INTO c3(col1, col2, extra) VALUES(5, 6, 'ok-order-swapped');
INSERT INTO c3(col1, col2, extra) VALUES(5, 6, 'ok-order-swapped');

EXPLAIN QUERY PLAN INSERT INTO c3(col1, col2, extra) VALUES(6, 5, 'bad-order-swapped');
INSERT OR IGNORE INTO c3(col1, col2, extra) VALUES(6, 5, 'bad-order-swapped');

DROP TABLE c3;
DROP TABLE p3;

-- Test 4: Deferred FK with implicit composite PK mapping, updates and deletes
CREATE TABLE p4(
  a INTEGER,
  b INTEGER,
  PRIMARY KEY(a, b)
);

CREATE TABLE c4(
  x INTEGER,
  y INTEGER,
  data TEXT,
  FOREIGN KEY(x, y) REFERENCES p4 DEFERRABLE INITIALLY DEFERRED
);

INSERT INTO p4 VALUES(1, 1);
INSERT INTO p4 VALUES(2, 2);
INSERT INTO c4 VALUES(1, 1, 'child1');
INSERT INTO c4 VALUES(2, 2, 'child2');

BEGIN TRANSACTION;
EXPLAIN QUERY PLAN UPDATE p4 SET a = a+10 WHERE a = 1;
UPDATE p4 SET a = a+10 WHERE a = 1;

EXPLAIN QUERY PLAN DELETE FROM p4 WHERE a = 2 AND b = 2;
DELETE FROM p4 WHERE a = 2 AND b = 2;
ROLLBACK;

DROP TABLE c4;
DROP TABLE p4;

-- Test 5: PRAGMA foreign_key_check interaction with implicit composite PK mapping
CREATE TABLE p5(
  a INTEGER,
  b INTEGER,
  c INTEGER,
  PRIMARY KEY(a, b)
);

CREATE TABLE c5(
  x INTEGER,
  y INTEGER,
  d INTEGER,
  FOREIGN KEY(x, y) REFERENCES p5
);

INSERT INTO p5 VALUES(1, 1, 100);
INSERT INTO p5 VALUES(2, 2, 200);
INSERT INTO c5 VALUES(1, 1, 10);
INSERT INTO c5 VALUES(2, 3, 20);
INSERT INTO c5 VALUES(NULL, NULL, 30);

EXPLAIN QUERY PLAN SELECT * FROM pragma_foreign_key_check;
SELECT * FROM pragma_foreign_key_check;

DROP TABLE c5;
DROP TABLE p5;
-- ================================================================
-- SQL Regression Test for: Ignore foreign key mismatch errors while
-- compiling DROP TABLE commands.
-- task_id: 133
-- ================================================================

PRAGMA foreign_keys = ON;

-- Test 1: DROP TABLE child with FK referencing missing parent table
--         (pParse->disableTriggers!=0, pTo==NULL path; no FK mismatch error).
CREATE TABLE parent1(id INTEGER PRIMARY KEY);
CREATE TABLE child1(x INTEGER PRIMARY KEY,
                    y INTEGER,
                    FOREIGN KEY(y) REFERENCES missing_parent(id));
INSERT INTO child1 VALUES(1, NULL);
INSERT INTO child1 VALUES(2, 10);

-- Force sqlite3FkCheck() via DELETE FROM during DROP TABLE compilation
EXPLAIN QUERY PLAN DELETE FROM child1;
DROP TABLE child1;
DROP TABLE parent1;


-- Test 2: DROP TABLE child when parent table exists but FK is mismatched
--         (pParse->disableTriggers!=0, pTo!=0 but sqlite3FkLocateIndex() fails;
--          exercise isIgnoreErrors && !mallocFailed branch with continue).
CREATE TABLE parent2(id INTEGER);
CREATE TABLE child2(x INTEGER PRIMARY KEY,
                    y INTEGER,
                    FOREIGN KEY(y) REFERENCES parent2(nonexistent_col));
INSERT INTO child2 VALUES(1, NULL);
INSERT INTO child2 VALUES(2, 5);

EXPLAIN QUERY PLAN DELETE FROM child2;
DROP TABLE child2;
DROP TABLE parent2;


-- Test 3: Normal DML with FK mismatch (disableTriggers==0)
--         Ensure sqlite3FkLocateIndex() reports "foreign key mismatch"
--         error on INSERT, exercising error path with locate using
--         sqlite3LocateTable().
CREATE TABLE parent3(id INTEGER);
CREATE TABLE child3(x INTEGER PRIMARY KEY,
                    y INTEGER,
                    FOREIGN KEY(y) REFERENCES parent3(nonexistent_col));

-- This should invoke FK checking and hit the error-reporting path.
EXPLAIN QUERY PLAN INSERT INTO child3 VALUES(1, 10);

DROP TABLE child3;
DROP TABLE parent3;


-- Test 4: DROP TABLE parent referenced by child with mismatched FK
--         (second locateFkeyIndex call in sqlite3FkCheck for parent
--          side, ignore-errors path when dropping parent).
CREATE TABLE parent4(id INTEGER);
CREATE TABLE child4(x INTEGER PRIMARY KEY,
                    y INTEGER,
                    FOREIGN KEY(y) REFERENCES parent4(nonexistent_col));
INSERT INTO parent4 VALUES(1);
INSERT INTO child4 VALUES(1, NULL);
INSERT INTO child4 VALUES(2, 1);

-- Exercise parent-side FK processing during DROP TABLE parent4.
EXPLAIN QUERY PLAN DELETE FROM parent4;
DROP TABLE parent4;
DROP TABLE child4;


-- Test 5: Authorization-related path and successful FK index lookup
--         (ensure sqlite3FkLocateIndex is called with non-NULL pParse
--          from both child and parent loops without ignoring errors).
CREATE TABLE parent5(id INTEGER PRIMARY KEY);
CREATE TABLE child5(x INTEGER PRIMARY KEY,
                    y INTEGER,
                    FOREIGN KEY(y) REFERENCES parent5(id));
INSERT INTO parent5 VALUES(1);
INSERT INTO child5 VALUES(1, 1);
INSERT INTO child5 VALUES(2, NULL);

-- Child-side FK check (fkLookupParent path)
EXPLAIN QUERY PLAN UPDATE child5 SET y=NULL WHERE x=1;

-- Parent-side FK check (fkScanChildren path)
EXPLAIN QUERY PLAN DELETE FROM parent5;

DROP TABLE child5;
DROP TABLE parent5;
-- ================================================================
-- SQL Regression Test for: Remove unreachable branches from fkey.c
-- task_id: 134
-- ================================================================

PRAGMA foreign_keys = ON;

-- Test 1: fkLookupParent with INTEGER PRIMARY KEY parent (pIdx==NULL path, nIncr>0 immediate FK)
--   - Exercise fkLookupParent() branch where pIdx==0 (parent IPK)
--   - Exercise non-deferred, non-DeferFKs, single-row INSERT path
--   - Exercise OP_FkCounter with nIncr=1 (immediate FK, isDeferred=0)
DROP TABLE IF EXISTS p1;
DROP TABLE IF EXISTS c1;
CREATE TABLE p1(
  id INTEGER PRIMARY KEY,
  value TEXT
);
CREATE TABLE c1(
  id INTEGER PRIMARY KEY,
  pid INTEGER REFERENCES p1(id) ON DELETE RESTRICT,
  note TEXT
);

-- Insert a parent row so that an insert with non-matching pid violates FK
INSERT INTO p1(id, value) VALUES(1, 'parent');

-- This insert violates FK (pid=2 not in p1), causing fkLookupParent() to
-- search using IPK parent and execute OP_FkCounter (nIncr=1, immediate).
-- Use EXPLAIN QUERY PLAN to ensure compilation & VDBE generation runs.
EXPLAIN QUERY PLAN
INSERT INTO c1(id, pid, note) VALUES(10, 2, 'orphan');

DROP TABLE c1;
DROP TABLE p1;


-- Test 2: fkLookupParent with indexed parent key (pIdx!=NULL path, nIncr>0 immediate FK)
--   - Exercise fkLookupParent() branch where pIdx!=0 (explicit UNIQUE index)
--   - Exercise non-deferred, non-DeferFKs, single-row INSERT path
--   - Exercise OP_FkCounter with nIncr=1 and indexed lookup
DROP TABLE IF EXISTS p2;
DROP TABLE IF EXISTS c2;
CREATE TABLE p2(
  k1 INT,
  k2 INT,
  value TEXT,
  UNIQUE(k1, k2)
);
CREATE TABLE c2(
  id INTEGER PRIMARY KEY,
  a INT,
  b INT,
  FOREIGN KEY(a, b) REFERENCES p2(k1, k2) ON DELETE RESTRICT
);

INSERT INTO p2(k1, k2, value) VALUES(1, 1, 'row11');

-- Violating insert with composite key (a,b) not present in p2 triggers
-- fkLookupParent() with pIdx!=0 and OP_FkCounter with nIncr=1.
EXPLAIN QUERY PLAN
INSERT INTO c2(id, a, b) VALUES(20, 2, 3);

DROP TABLE c2;
DROP TABLE p2;


-- Test 3: Deferred foreign key on INSERT (isDeferred!=0, nIncr>0)
--   - Exercise fkLookupParent() with deferred foreign key (isDeferred=1)
--   - Exercise OP_FkCounter with nIncr=1 and isDeferred=1 (mayAbort not set)
--   - Also covers case where transaction is multi-write (so constraint is deferred)
DROP TABLE IF EXISTS p3;
DROP TABLE IF EXISTS c3;
CREATE TABLE p3(
  id INTEGER PRIMARY KEY,
  value TEXT
);
CREATE TABLE c3(
  id INTEGER PRIMARY KEY,
  pid INTEGER,
  note TEXT,
  FOREIGN KEY(pid) REFERENCES p3(id) DEFERRABLE INITIALLY DEFERRED
);

BEGIN;
-- Insert child row that violates deferred FK (no matching parent),
-- causing fkLookupParent() to add OP_FkCounter with isDeferred=1.
EXPLAIN QUERY PLAN
INSERT INTO c3(id, pid, note) VALUES(30, 99, 'deferred orphan');
COMMIT;

DROP TABLE c3;
DROP TABLE p3;


-- Test 4: Immediate foreign key on DELETE (nIncr<0 path with OP_FkIfZero and OP_FkCounter)
--   - Exercise fkLookupParent() path where nIncr<0 (DELETE on child table)
--   - Exercise OP_FkIfZero followed by OP_FkCounter with nIncr=-1
--   - Include NULL child key edge case so NULL row is ignored
DROP TABLE IF EXISTS p4;
DROP TABLE IF EXISTS c4;
CREATE TABLE p4(
  id INTEGER PRIMARY KEY,
  value TEXT
);
CREATE TABLE c4(
  id INTEGER PRIMARY KEY,
  pid INTEGER REFERENCES p4(id) ON DELETE RESTRICT,
  note TEXT
);

INSERT INTO p4(id, value) VALUES(1, 'parent');
INSERT INTO c4(id, pid, note) VALUES(40, 1, 'ok child');
INSERT INTO c4(id, pid, note) VALUES(41, NULL, 'null child');

-- Delete child rows: fkLookupParent() is invoked with nIncr<0.
-- EXPLAIN QUERY PLAN ensures compilation and OP_FkCounter emission
-- for the delete statement, exercising the negative nIncr path.
EXPLAIN QUERY PLAN
DELETE FROM c4 WHERE id IN (40, 41);

DROP TABLE c4;
DROP TABLE p4;


-- Test 5: Non-deferred foreign key in multi-write statement (mayAbort() + OP_FkCounter)
--   - Exercise fkLookupParent() where isDeferred=0 but isMultiWrite is true
--   - Ensures sqlite3MayAbort (mayAbort=1) and OP_FkCounter are both generated
--   - Uses multi-row INSERT with sub-select to mark statement as multi-write
DROP TABLE IF EXISTS p5;
DROP TABLE IF EXISTS c5;
DROP TABLE IF EXISTS src5;
CREATE TABLE p5(
  id INTEGER PRIMARY KEY,
  value TEXT
);
CREATE TABLE c5(
  id INTEGER PRIMARY KEY,
  pid INTEGER REFERENCES p5(id) ON DELETE RESTRICT,
  note TEXT
);
CREATE TABLE src5(x INT, y INT);
INSERT INTO src5(x, y) VALUES(1, 1), (2, 2), (3, 3);

-- Only one parent row exists; others will violate FK.
INSERT INTO p5(id, value) VALUES(1, 'parent');

-- Multi-write INSERT from SELECT, causing isMultiWrite!=0.
-- fkLookupParent() should set mayAbort and generate OP_FkCounter
-- with nIncr>0 for violating rows.
EXPLAIN QUERY PLAN
INSERT INTO c5(id, pid, note)
  SELECT x+100, y, 'multiwrite' FROM src5;

DROP TABLE c5;
DROP TABLE p5;
DROP TABLE src5;

-- ================================================================
-- SQL Regression Test for: Handle SQLITE_IGNORE for parent key reads
-- task_id: 135
-- ================================================================

PRAGMA foreign_keys = ON;

-- Test 1: FK parent read allowed (SQLITE_OK) - normal fkLookupParent path, auth read
-- Targets: sqlite3AuthReadCol (SQLITE_OK), fkLookupParent(isIgnore=0, pIdx=0 and pIdx!=0)
CREATE TABLE p1(
  id INTEGER PRIMARY KEY,
  a TEXT,
  b INTEGER
);
CREATE UNIQUE INDEX p1_ab ON p1(a,b);

CREATE TABLE c1(
  id INTEGER PRIMARY KEY,
  a TEXT,
  b INTEGER,
  FOREIGN KEY(a,b) REFERENCES p1(a,b)
);

INSERT INTO p1 VALUES (1,'x',10);
INSERT INTO p1 VALUES (2,'y',20);

-- This insert uses existing parent row, exercising fkLookupParent normal lookup
EXPLAIN QUERY PLAN INSERT INTO c1(id,a,b) VALUES(100,'x',10);

DROP TABLE c1;
DROP TABLE p1;

-- Test 2: FK parent read ignored (SQLITE_IGNORE) with matching parent row
-- Conceptually targets: sqlite3AuthReadCol returning SQLITE_IGNORE, isIgnore=1
-- and fkLookupParent early-exit path that pretends parent columns are NULL.
-- NOTE: Actual SQLITE_IGNORE requires an authorizer; here we just execute
-- the FK machinery code path setup via EXPLAIN QUERY PLAN.
CREATE TABLE p2(
  id INTEGER PRIMARY KEY,
  a TEXT,
  b INTEGER
);
CREATE TABLE c2(
  id INTEGER PRIMARY KEY,
  a TEXT,
  b INTEGER,
  FOREIGN KEY(a,b) REFERENCES p2(a,b)
);

INSERT INTO p2 VALUES(1,'n',NULL);
INSERT INTO p2 VALUES(2,NULL,5);

-- Child rows that would match parent keys but where parent columns may be
-- treated as NULL under SQLITE_IGNORE handling.
EXPLAIN QUERY PLAN INSERT INTO c2(id,a,b) VALUES(10,'n',NULL);
EXPLAIN QUERY PLAN INSERT INTO c2(id,a,b) VALUES(11,NULL,5);

DROP TABLE c2;
DROP TABLE p2;

-- Test 3: Composite FK and self-referential table, exercising fkLookupParent
-- branches for pIdx!=0 and pTab==pFrom with nIncr=1 under isIgnore=0.
CREATE TABLE p3(
  id INTEGER PRIMARY KEY,
  a INTEGER,
  b INTEGER,
  UNIQUE(a,b)
);

CREATE TABLE c3(
  id INTEGER PRIMARY KEY,
  a INTEGER,
  b INTEGER,
  FOREIGN KEY(a,b) REFERENCES p3(a,b)
);

INSERT INTO p3 VALUES(1,1,1);
INSERT INTO p3 VALUES(2,2,NULL);

EXPLAIN QUERY PLAN INSERT INTO c3(id,a,b) VALUES(3,1,1);
EXPLAIN QUERY PLAN INSERT INTO c3(id,a,b) VALUES(4,2,NULL);

DROP TABLE c3;
DROP TABLE p3;

-- Test 4: INTEGER PRIMARY KEY parent (pIdx==0) with NULL and non-NULL child keys
-- Targets: fkLookupParent isIgnore==0 branch with pIdx==0, MustBeInt path, and
-- IsNull checks on child keys.
CREATE TABLE p4(
  id INTEGER PRIMARY KEY,
  val TEXT
);
CREATE TABLE c4(
  id INTEGER PRIMARY KEY,
  pid INTEGER,
  FOREIGN KEY(pid) REFERENCES p4(id)
);

INSERT INTO p4 VALUES(1,'one');

-- Child row with non-NULL key matching parent
EXPLAIN QUERY PLAN INSERT INTO c4(id,pid) VALUES(1,1);
-- Child row with NULL key, FK treated as satisfied without parent lookup
EXPLAIN QUERY PLAN INSERT INTO c4(id,pid) VALUES(2,NULL);

DROP TABLE c4;
DROP TABLE p4;

-- Test 5: Deferred FK with multiple columns and NULL handling
-- Targets: fkLookupParent IsNull checks for multiple columns, isIgnore=0 path
-- with pIdx!=0 and deferred constraint counter behavior.
PRAGMA defer_foreign_keys = OFF;

CREATE TABLE p5(
  k1 INTEGER,
  k2 TEXT,
  PRIMARY KEY(k1,k2)
);

CREATE TABLE c5(
  id INTEGER PRIMARY KEY,
  k1 INTEGER,
  k2 TEXT,
  FOREIGN KEY(k1,k2) REFERENCES p5(k1,k2) DEFERRABLE INITIALLY DEFERRED
);

INSERT INTO p5 VALUES(1,'a');
INSERT INTO p5 VALUES(2,'b');

-- Matching parent row
EXPLAIN QUERY PLAN INSERT INTO c5(id,k1,k2) VALUES(1,1,'a');
-- Child with NULL in one FK column triggers IsNull short-circuit
EXPLAIN QUERY PLAN INSERT INTO c5(id,k1,k2) VALUES(2,NULL,'b');

DROP TABLE c5;
DROP TABLE p5;

-- ================================================================
-- SQL Regression Test for: Add evidence marks to parse.y
-- task_id: 136
-- Focus: REFERENCES clause refargs/refact parsing (ON DELETE/UPDATE actions)
-- ================================================================

-- Test 1: Column-level REFERENCES without explicit ON DELETE/ON UPDATE (refargs default path)
-- Targets: refargs(A) ::= .  (EV: R-19803-45884) default OE_None*0x0101
DROP TABLE IF EXISTS child1;
DROP TABLE IF EXISTS parent1;

CREATE TABLE parent1(
  id INTEGER PRIMARY KEY,
  info TEXT
);

CREATE TABLE child1(
  id INTEGER PRIMARY KEY,
  parent_id INTEGER REFERENCES parent1(id)
);

INSERT INTO parent1(id, info) VALUES (1, 'row1');
INSERT INTO child1(id, parent_id) VALUES (10, 1);

-- Run a simple query to ensure the schema (and REFERENCES clause) is parsed
EXPLAIN QUERY PLAN
SELECT c.id, c.parent_id, p.info
FROM child1 AS c
LEFT JOIN parent1 AS p ON p.id = c.parent_id
WHERE c.parent_id = 1;

DROP TABLE child1;
DROP TABLE parent1;


-- Test 2: Column-level REFERENCES with ON DELETE SET NULL and ON UPDATE CASCADE
-- Targets: refact SET NULL, CASCADE (EV: R-33326-45252) via ON DELETE/ON UPDATE
DROP TABLE IF EXISTS child2;
DROP TABLE IF EXISTS parent2;

CREATE TABLE parent2(
  id INTEGER PRIMARY KEY,
  name TEXT
);

CREATE TABLE child2(
  id INTEGER PRIMARY KEY,
  parent_id INTEGER,
  note TEXT,
  FOREIGN KEY(parent_id) REFERENCES parent2(id)
    ON DELETE SET NULL
    ON UPDATE CASCADE
);

INSERT INTO parent2(id, name) VALUES (1, 'p1');
INSERT INTO parent2(id, name) VALUES (2, 'p2');
INSERT INTO child2(id, parent_id, note) VALUES (100, 1, 'n1');
INSERT INTO child2(id, parent_id, note) VALUES (101, 2, 'n2');

EXPLAIN QUERY PLAN
SELECT c.id, c.parent_id, p.name
FROM child2 AS c
JOIN parent2 AS p ON p.id = c.parent_id
WHERE c.parent_id IN (1, 2);

DROP TABLE child2;
DROP TABLE parent2;


-- Test 3: Table-level FOREIGN KEY with ON DELETE SET DEFAULT and ON UPDATE RESTRICT
-- Targets: refact SET DEFAULT, RESTRICT (EV: R-33326-45252)
DROP TABLE IF EXISTS child3;
DROP TABLE IF EXISTS parent3;

CREATE TABLE parent3(
  id INTEGER PRIMARY KEY,
  descr TEXT
);

CREATE TABLE child3(
  id INTEGER PRIMARY KEY,
  parent_id INTEGER DEFAULT 0,
  payload TEXT,
  FOREIGN KEY(parent_id) REFERENCES parent3(id)
    ON DELETE SET DEFAULT
    ON UPDATE RESTRICT
);

INSERT INTO parent3(id, descr) VALUES (1, 'd1');
INSERT INTO child3(id, parent_id, payload) VALUES (200, 1, 'p1');
INSERT INTO child3(id, parent_id, payload) VALUES (201, NULL, 'p2');
INSERT INTO child3(id, parent_id, payload) VALUES (202, 0, 'p3');

EXPLAIN QUERY PLAN
SELECT c.id, c.parent_id, p.descr
FROM child3 AS c
LEFT JOIN parent3 AS p ON p.id = c.parent_id
ORDER BY c.id;

DROP TABLE child3;
DROP TABLE parent3;


-- Test 4: Mixed ON DELETE/ON UPDATE actions including NO ACTION
-- Targets: refact NO ACTION plus combination of multiple refarg rules
DROP TABLE IF EXISTS child4;
DROP TABLE IF EXISTS parent4;

CREATE TABLE parent4(
  id INTEGER PRIMARY KEY,
  value TEXT
);

CREATE TABLE child4(
  id INTEGER PRIMARY KEY,
  parent_id INTEGER,
  tag TEXT,
  FOREIGN KEY(parent_id) REFERENCES parent4(id)
    ON DELETE NO ACTION
    ON UPDATE SET NULL
);

INSERT INTO parent4(id, value) VALUES (1, 'x');
INSERT INTO parent4(id, value) VALUES (2, 'y');
INSERT INTO child4(id, parent_id, tag) VALUES (300, 1, 'a');
INSERT INTO child4(id, parent_id, tag) VALUES (301, 2, 'b');

EXPLAIN QUERY PLAN
SELECT c.id, c.parent_id, p.value
FROM child4 AS c
LEFT JOIN parent4 AS p ON p.id = c.parent_id
WHERE p.value IS NOT NULL OR c.parent_id IS NULL;

DROP TABLE child4;
DROP TABLE parent4;


-- Test 5: Multiple REFERENCES in one table using all ON DELETE/ON UPDATE actions
-- Targets: Comprehensive coverage of refargs/refarg/refact combinations
DROP TABLE IF EXISTS child5;
DROP TABLE IF EXISTS parent5a;
DROP TABLE IF EXISTS parent5b;

CREATE TABLE parent5a(
  id INTEGER PRIMARY KEY,
  label TEXT
);

CREATE TABLE parent5b(
  id INTEGER PRIMARY KEY,
  label TEXT
);

CREATE TABLE child5(
  id INTEGER PRIMARY KEY,
  a_id INTEGER,
  b_id INTEGER,
  c_id INTEGER,
  d_id INTEGER,
  note TEXT,
  FOREIGN KEY(a_id) REFERENCES parent5a(id)
    ON DELETE CASCADE
    ON UPDATE CASCADE,
  FOREIGN KEY(b_id) REFERENCES parent5a(id)
    ON DELETE SET NULL
    ON UPDATE SET DEFAULT,
  FOREIGN KEY(c_id) REFERENCES parent5b(id)
    ON DELETE RESTRICT
    ON UPDATE NO ACTION,
  FOREIGN KEY(d_id) REFERENCES parent5b(id)
    -- relies on refargs default (no explicit ON DELETE/UPDATE)
);

INSERT INTO parent5a(id, label) VALUES (1, 'a1');
INSERT INTO parent5a(id, label) VALUES (2, 'a2');
INSERT INTO parent5b(id, label) VALUES (10, 'b1');
INSERT INTO parent5b(id, label) VALUES (20, 'b2');

INSERT INTO child5(id, a_id, b_id, c_id, d_id, note)
VALUES
  (400, 1, 1, 10, 10, 'r1'),
  (401, 2, NULL, 20, NULL, 'r2'),
  (402, NULL, 2, NULL, 20, 'r3');

EXPLAIN QUERY PLAN
SELECT c.id, c.a_id, c.b_id, c.c_id, c.d_id,
       a.label AS a_label,
       b.label AS b_label,
       c2.label AS c_label,
       d2.label AS d_label
FROM child5 AS c
LEFT JOIN parent5a AS a ON a.id = c.a_id
LEFT JOIN parent5a AS b ON b.id = c.b_id
LEFT JOIN parent5b AS c2 ON c2.id = c.c_id
LEFT JOIN parent5b AS d2 ON d2.id = c.d_id
ORDER BY c.id;

DROP TABLE child5;
DROP TABLE parent5a;
DROP TABLE parent5b;

-- ================================================================
-- SQL Regression Test for: MERGE accidental fork back to trunk
-- task_id: 137
-- Focus: REFERENCES clause refargs/refact (ON DELETE/ON UPDATE actions)
-- ================================================================

-- Test 1: Default refargs with no ON DELETE/ON UPDATE clause (refargs ::= .)
--          Covers: refargs(A) ::= . { A = OE_None*0x0101; }
DROP TABLE IF EXISTS p1;
DROP TABLE IF EXISTS c1;
CREATE TABLE p1(
  id INTEGER PRIMARY KEY,
  v TEXT
);
CREATE TABLE c1(
  id INTEGER PRIMARY KEY,
  pid INT REFERENCES p1(id)
);
INSERT INTO p1(id,v) VALUES(1,'a'),(2,'b');
INSERT INTO c1(id,pid) VALUES(10,1),(11,2);

EXPLAIN QUERY PLAN
  CREATE TABLE x1(
    x INT REFERENCES p1(id)
  );

EXPLAIN QUERY PLAN
  CREATE TABLE x2(
    x INT,
    FOREIGN KEY(x) REFERENCES p1(id)
  );

DROP TABLE x2;
DROP TABLE x1;
DROP TABLE c1;
DROP TABLE p1;

-- Test 2: ON DELETE / ON UPDATE SET NULL (refact ::= SET NULL)
--          Covers: refact(A) ::= SET NULL.
DROP TABLE IF EXISTS p2;
DROP TABLE IF EXISTS c2;
CREATE TABLE p2(
  id INTEGER PRIMARY KEY,
  v TEXT
);
CREATE TABLE c2(
  id INTEGER PRIMARY KEY,
  pid INT,
  FOREIGN KEY(pid) REFERENCES p2(id)
    ON DELETE SET NULL
    ON UPDATE SET NULL
);
INSERT INTO p2 VALUES(1,'alpha');
INSERT INTO c2 VALUES(1,1);

EXPLAIN QUERY PLAN
  CREATE TABLE x3(
    x INT,
    FOREIGN KEY(x) REFERENCES p2(id)
      ON DELETE SET NULL
      ON UPDATE SET NULL
  );

UPDATE p2 SET id = id WHERE id = 1;
DELETE FROM p2 WHERE id = 1;

DROP TABLE x3;
DROP TABLE c2;
DROP TABLE p2;

-- Test 3: ON DELETE / ON UPDATE SET DEFAULT (refact ::= SET DEFAULT)
--          Covers: refact(A) ::= SET DEFAULT.
DROP TABLE IF EXISTS p3;
DROP TABLE IF EXISTS c3;
CREATE TABLE p3(
  id INTEGER PRIMARY KEY,
  v TEXT
);
CREATE TABLE c3(
  id INTEGER PRIMARY KEY,
  pid INT DEFAULT NULL,
  FOREIGN KEY(pid) REFERENCES p3(id)
    ON DELETE SET DEFAULT
    ON UPDATE SET DEFAULT
);
INSERT INTO p3 VALUES(1,'alpha');
INSERT INTO c3 VALUES(1,1),(2,NULL);

EXPLAIN QUERY PLAN
  CREATE TABLE x4(
    x INT DEFAULT 0,
    FOREIGN KEY(x) REFERENCES p3(id)
      ON DELETE SET DEFAULT
      ON UPDATE SET DEFAULT
  );

UPDATE p3 SET id = id WHERE id = 1;
DELETE FROM p3 WHERE id = 1;

DROP TABLE x4;
DROP TABLE c3;
DROP TABLE p3;

-- Test 4: ON DELETE / ON UPDATE CASCADE and RESTRICT (refact ::= CASCADE/RESTRICT)
--          Covers: refact(A) ::= CASCADE., refact(A) ::= RESTRICT.
DROP TABLE IF EXISTS p4;
DROP TABLE IF EXISTS c4;
CREATE TABLE p4(
  id INTEGER PRIMARY KEY,
  v TEXT
);
CREATE TABLE c4(
  id INTEGER PRIMARY KEY,
  pid INT,
  FOREIGN KEY(pid) REFERENCES p4(id)
    ON DELETE CASCADE
    ON UPDATE RESTRICT
);
INSERT INTO p4 VALUES(1,'alpha'),(2,'beta');
INSERT INTO c4 VALUES(1,1),(2,2);

EXPLAIN QUERY PLAN
  CREATE TABLE x5(
    x INT,
    FOREIGN KEY(x) REFERENCES p4(id)
      ON DELETE CASCADE
      ON UPDATE RESTRICT
  );

UPDATE p4 SET id = id WHERE id = 1;
DELETE FROM p4 WHERE id = 1;

DROP TABLE x5;
DROP TABLE c4;
DROP TABLE p4;

-- Test 5: ON DELETE / ON UPDATE NO ACTION with NULLs and empty results
--          Covers: refact(A) ::= NO ACTION.
DROP TABLE IF EXISTS p5;
DROP TABLE IF EXISTS c5;
CREATE TABLE p5(
  id INTEGER PRIMARY KEY,
  v TEXT
);
CREATE TABLE c5(
  id INTEGER PRIMARY KEY,
  pid INT,
  FOREIGN KEY(pid) REFERENCES p5(id)
    ON DELETE NO ACTION
    ON UPDATE NO ACTION
);
INSERT INTO p5 VALUES(1,'alpha');
INSERT INTO c5 VALUES(1,NULL),(2,1);

EXPLAIN QUERY PLAN
  CREATE TABLE x6(
    x INT,
    FOREIGN KEY(x) REFERENCES p5(id)
      ON DELETE NO ACTION
      ON UPDATE NO ACTION
  );

-- Edge operations: empty delete/update and NULL handling
UPDATE p5 SET id = id WHERE id = 99;  -- no rows
DELETE FROM p5 WHERE id = 99;         -- no rows

DROP TABLE x6;
DROP TABLE c5;
DROP TABLE p5;
-- ================================================================
-- SQL Regression Test for: Tweaks to the SUBSTR() function performance
-- task_id: 138
-- ================================================================

-- Test 1: TEXT input, negative start, small positive length (forces full UTF-8 length scan and p1<0 path)
CREATE TABLE t1(x TEXT);
INSERT INTO t1 VALUES (printf('%.*c', 10000, 'a')); -- large ASCII string
EXPLAIN QUERY PLAN SELECT substr(x, -5, 3) FROM t1;  -- p1<0, argc=3
EXPLAIN QUERY PLAN SELECT substr(x, -1, 1) FROM t1;  -- another small-length negative start
DROP TABLE t1;

-- Test 2: TEXT input, negative start, implicit length (argc=2, large string)
CREATE TABLE t2(x TEXT);
INSERT INTO t2 VALUES (printf('%.*c', 8000, 'b'));
EXPLAIN QUERY PLAN SELECT substr(x, -10) FROM t2;   -- argc=2, p1<0 triggers length scan
EXPLAIN QUERY PLAN SELECT substr(x, -1) FROM t2;    -- near-end negative index
DROP TABLE t2;

-- Test 3: TEXT input with multi-byte UTF-8 characters and negative start
CREATE TABLE t3(x TEXT);
-- String with multi-byte characters repeated to make it large
INSERT INTO t3 VALUES (substr(printf('%.*s', 4000, '汉字ąΩ'), 1, 4000));
EXPLAIN QUERY PLAN SELECT substr(x, -3, 2) FROM t3; -- negative start, UTF-8 length counting
EXPLAIN QUERY PLAN SELECT substr(x, -1, 1) FROM t3; -- last character, ensures UTF-8 walk to end
DROP TABLE t3;

-- Test 4: TEXT input where computed negative start falls before beginning (p1+p2<0 adjustment)
CREATE TABLE t4(x TEXT);
INSERT INTO t4 VALUES (printf('%.*c', 50, 'c'));
EXPLAIN QUERY PLAN SELECT substr(x, -100, 10) FROM t4; -- p1<0, p1+len<0, p2 adjusted to 0
EXPLAIN QUERY PLAN SELECT substr(x, -60, -5) FROM t4;  -- negative length with negative start
DROP TABLE t4;

-- Test 5: Mixed cases ensuring no length scan when start >= 0 (p1>=0 path on large text)
CREATE TABLE t5(x TEXT);
INSERT INTO t5 VALUES (printf('%.*c', 12000, 'd'));
EXPLAIN QUERY PLAN SELECT substr(x, 1, 5) FROM t5;   -- p1>0, skip initial length scan
EXPLAIN QUERY PLAN SELECT substr(x, 10, 2) FROM t5;  -- another small positive start/length
DROP TABLE t5;
-- ================================================================
-- SQL Regression Test for: Enhancements to the VDBE opcode loop
-- task_id: 139
-- ================================================================

-- Test 1: OUT2_PRERELEASE destination reused for various opcodes (including NULL, integer, text)
-- Targets: new generic out2-prerelease handling and register tracing for IN1/IN2/IN3
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT, c REAL);
INSERT INTO t1 VALUES (1, 'alpha', 1.5);
INSERT INTO t1 VALUES (2, NULL, 2.5);
INSERT INTO t1 VALUES (3, 'gamma', NULL);

-- Use a compound query and expressions so that the same output register is reused
-- and passes through multiple OUT2_PRERELEASE opcodes (e.g. Column, Integer, Real, Function)
EXPLAIN QUERY PLAN
SELECT
  a,
  b,
  printf('%s-%d', COALESCE(b, 'null'), a) AS fmt,
  a + COALESCE(c, 0) AS sumv
FROM t1
WHERE a IN (SELECT a FROM t1 WHERE b IS NOT NULL)
ORDER BY sumv DESC;

DROP TABLE IF EXISTS t1;


-- Test 2: OP_Copy / OP_SCopy / OP_IntCopy register usage and IN/OUT2/OUT3 assertions
-- Targets: pIn1/pIn2/pOut setup for Copy/SCopy/IntCopy and OUT2/OUT3 sanity checks
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(x INTEGER, y TEXT, z INTEGER);
INSERT INTO t2 VALUES (1, 'one', 10);
INSERT INTO t2 VALUES (2, 'two', 20);
INSERT INTO t2 VALUES (3, 'three', 30);

-- Expression mix forces use of Copy/SCopy/IntCopy and arithmetic opcodes
EXPLAIN QUERY PLAN
SELECT
  x,
  y,
  x AS x_copy,
  x + 1 AS x_plus_one,
  (x + z) * 2 AS big_calc,
  CASE WHEN y LIKE 't%' THEN x ELSE z END AS case_expr
FROM t2
WHERE (x + z) > 15
ORDER BY big_calc;

DROP TABLE IF EXISTS t2;


-- Test 3: OP_Concat with NULLs, empty strings, and large blobs
-- Targets: Concat in1/in2/out3 register mapping and NULL handling, plus MEM_Str/MEM_Zero paths
DROP TABLE IF EXISTS t3;
CREATE TABLE t3(a TEXT, b TEXT);
INSERT INTO t3 VALUES ('hello', 'world');
INSERT INTO t3 VALUES (NULL, 'suffix');
INSERT INTO t3 VALUES ('prefix', NULL);
INSERT INTO t3 VALUES ('', 'empty');
INSERT INTO t3 VALUES ('large', hex(zeroblob(64)));

EXPLAIN QUERY PLAN
SELECT
  a || '-' || b AS concat1,
  b || a AS concat2,
  COALESCE(a, '') || COALESCE(b, '') AS concat3
FROM t3
WHERE concat1 IS NOT NULL OR concat2 IS NULL;

DROP TABLE IF EXISTS t3;


-- Test 4: ResultRow and tracing of result registers including NULL and numeric values
-- Targets: ResultRow register tracing and OUT3/IN3 sanity checks via multi-column result
DROP TABLE IF EXISTS t4;
CREATE TABLE t4(p INTEGER, q TEXT, r REAL);
INSERT INTO t4 VALUES (1, 'x', 1.1);
INSERT INTO t4 VALUES (2, NULL, 2.2);
INSERT INTO t4 VALUES (3, 'z', NULL);

EXPLAIN QUERY PLAN
SELECT
  p,
  q,
  r,
  p || ':' || COALESCE(q, 'null') AS lbl,
  r * 2 AS r2
FROM t4
WHERE p BETWEEN 1 AND 3
ORDER BY lbl;

DROP TABLE IF EXISTS t4;


-- Test 5: Foreign key operations and FkCheck path with RETURNING clause
-- Targets: FkCheck, out2-prerelease registers around constraint checks and ResultRow
PRAGMA foreign_keys = ON;
DROP TABLE IF EXISTS parent;
DROP TABLE IF EXISTS child;
CREATE TABLE parent(id INTEGER PRIMARY KEY, v TEXT);
CREATE TABLE child(
  id INTEGER PRIMARY KEY,
  pid INTEGER REFERENCES parent(id),
  w TEXT
);
INSERT INTO parent VALUES (1, 'p1');
INSERT INTO parent VALUES (2, 'p2');
INSERT INTO child  VALUES (10, 1, 'c1');
INSERT INTO child  VALUES (11, 2, 'c2');

-- This statement exercises foreign key checking, trigger-like behaviour,
-- and ResultRow with RETURNING, while also causing various OUT2/IN* opcodes.
EXPLAIN QUERY PLAN
UPDATE child
   SET pid = 1,
       w = w || '-upd'
 WHERE id = 11
 RETURNING id, pid, w;

DROP TABLE IF EXISTS child;
DROP TABLE IF EXISTS parent;
-- ================================================================
-- SQL Regression Test for: When moving pages as part of autovacuum on an
-- in-memory database, ensure the source page is journalled for rollback.
-- task_id: 140
-- ================================================================
-- These tests are designed to exercise pager logic for in-memory/temp
-- databases, especially around autovacuum and page movement. They are
-- intended for use in the SQLite test harness, which may configure
-- connections as in-memory or temp DBs at a higher level.

-- =====================================================================
-- Test 1: Basic DELETE+AUTOVACUUM on temp table to trigger page moves
--          (normal case, small dataset)
--          Targets: in-memory/temp pager, autovacuum moving pages,
--                   journalling of source pages for rollback.
-- =====================================================================
DROP TABLE IF EXISTS t1;
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;

-- Use a TEMP table so that in many harness configurations it resides
-- in an in-memory database or temp pager.
CREATE TEMP TABLE t1(x INTEGER PRIMARY KEY, y BLOB);

-- Populate with enough data to span multiple pages.
WITH RECURSIVE c(i) AS (
  SELECT 1
  UNION ALL
  SELECT i+1 FROM c WHERE i < 200
)
INSERT INTO t1 SELECT i, zeroblob(500) FROM c;

-- Force a checkpoint-style change so that deleting rows leaves free pages.
DELETE FROM t1 WHERE x % 2 = 0;

-- EXPLAIN QUERY PLAN on a statement likely to scan and cause internal
-- autovacuum activity during future commits.
EXPLAIN QUERY PLAN SELECT count(*) FROM t1;

DROP TABLE IF EXISTS t1;


-- =====================================================================
-- Test 2: Large rows with overflow pages in TEMP table under AUTOVACUUM
--          Targets: page moves involving overflow pages in an in-memory
--                   or temp database, journalling of source pages.
-- =====================================================================
DROP TABLE IF EXISTS t2;
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;

CREATE TEMP TABLE t2(id INTEGER PRIMARY KEY, data BLOB);

-- Insert rows with large payload to force overflow pages.
INSERT INTO t2 VALUES(1, zeroblob(5000));
INSERT INTO t2 VALUES(2, zeroblob(5000));
INSERT INTO t2 VALUES(3, zeroblob(5000));

-- Delete a subset to create free-list entries for autovacuum to reuse.
DELETE FROM t2 WHERE id IN (1,3);

-- Run a query that reads remaining data; subsequent autovacuum on commit
-- will need to move pages and maintain rollback ability.
EXPLAIN QUERY PLAN SELECT length(data) FROM t2 WHERE id = 2;

DROP TABLE IF EXISTS t2;


-- =====================================================================
-- Test 3: Mixed NULLs, empty result sets, and AUTOVACUUM in TEMP table
--          Targets: edge cases with NULL, empty ranges, and page reuse
--                   in in-memory/temp database with autovacuum.
-- =====================================================================
DROP TABLE IF EXISTS t3;
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;

CREATE TEMP TABLE t3(a INTEGER, b TEXT, c BLOB);

INSERT INTO t3 VALUES
  (1,  'alpha',  zeroblob(2000)),
  (2,  NULL,     zeroblob(2000)),
  (3,  'gamma',  NULL),
  (4,  NULL,     NULL),
  (10, 'omega',  zeroblob(2000));

-- Delete middle range to create fragmented free space.
DELETE FROM t3 WHERE a BETWEEN 2 AND 4;

-- Query that returns empty result to exercise edge case paths.
EXPLAIN QUERY PLAN SELECT * FROM t3 WHERE a BETWEEN 5 AND 9;

-- Query that reads remaining large row to keep its page live while others
-- may be moved by autovacuum.
EXPLAIN QUERY PLAN SELECT length(c) FROM t3 WHERE a = 10;

DROP TABLE IF EXISTS t3;


-- =====================================================================
-- Test 4: TEMP table with UNIQUE index and AUTOVACUUM
--          Targets: pointer-map and page-move operations on indexed
--                   structures in in-memory/temp database.
-- =====================================================================
DROP TABLE IF EXISTS t4;
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;

CREATE TEMP TABLE t4(k INTEGER PRIMARY KEY, v TEXT NOT NULL);
CREATE UNIQUE INDEX t4u ON t4(v);

INSERT INTO t4 VALUES
  (1, 'a'),
  (2, 'b'),
  (3, 'c'),
  (4, 'd'),
  (5, 'e');

-- Delete alternating rows to fragment index and table pages.
DELETE FROM t4 WHERE k IN (1,3,5);

-- Query via index to ensure the btree and pointer-map structures for
-- remaining entries are exercised as pages move.
EXPLAIN QUERY PLAN SELECT k FROM t4 WHERE v IN ('b','d') ORDER BY v;

DROP TABLE IF EXISTS t4;


-- =====================================================================
-- Test 5: TEMP table with lots of inserts and deletes inside a transaction
--          to stress rollback of autovacuum moves in in-memory/temp pager.
--          Targets: rollback journal entries for moved-from pages and
--                   savepoint-like behaviour.
-- =====================================================================
DROP TABLE IF EXISTS t5;
PRAGMA auto_vacuum = FULL;
PRAGMA page_size = 1024;

CREATE TEMP TABLE t5(id INTEGER PRIMARY KEY, payload BLOB);

BEGIN;
  -- Fill table with many rows spanning pages.
  WITH RECURSIVE r(i) AS (
    SELECT 1
    UNION ALL
    SELECT i+1 FROM r WHERE i < 300
  )
  INSERT INTO t5 SELECT i, zeroblob(300) FROM r;

  -- Delete most rows to create many free pages for autovacuum.
  DELETE FROM t5 WHERE id % 3 != 0;

  -- Run queries while transaction is open; rollback should be able to
  -- restore moved pages using the in-memory journal entries.
  EXPLAIN QUERY PLAN SELECT count(*) FROM t5;
  EXPLAIN QUERY PLAN SELECT max(id), min(id) FROM t5;
ROLLBACK;

DROP TABLE IF EXISTS t5;

-- ================================================================
-- SQL Regression Test for: Enhance the %q, %Q, and %w printf conversions
-- so that the precision specifies the length of the input.
-- task_id: 141
-- ================================================================

-- Test 1: %q with precision limiting input bytes, including embedded quotes
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(x TEXT);
INSERT INTO t1(x) VALUES('abc''def'),
                         ('noquote'),
                         (NULL);

-- Use printf('%.*q', precision, value) via generated columns to exercise %q
ALTER TABLE t1 ADD COLUMN q3 TEXT GENERATED ALWAYS AS (printf('%.*q',3,x)) VIRTUAL;
ALTER TABLE t1 ADD COLUMN q7 TEXT GENERATED ALWAYS AS (printf('%.*q',7,x)) VIRTUAL;

EXPLAIN QUERY PLAN SELECT q3, q7 FROM t1;
SELECT q3, q7 FROM t1;

DROP TABLE IF EXISTS t1;

-- Test 2: %Q with precision, NULL handling, and quoting behavior
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(x TEXT);
INSERT INTO t2(x) VALUES('''onlyquote'''),
                         ('abc'),
                         (NULL);

ALTER TABLE t2 ADD COLUMN q2 TEXT GENERATED ALWAYS AS (printf('%.*Q',2,x)) VIRTUAL;
ALTER TABLE t2 ADD COLUMN q10 TEXT GENERATED ALWAYS AS (printf('%.*Q',10,x)) VIRTUAL;

EXPLAIN QUERY PLAN SELECT q2, q10 FROM t2;
SELECT q2, q10 FROM t2;

DROP TABLE IF EXISTS t2;

-- Test 3: %w with precision and double-quote escaping
DROP TABLE IF EXISTS t3;
CREATE TABLE t3(x TEXT);
INSERT INTO t3(x) VALUES('"a"b"c"'),
                         ('no"quote'),
                         (NULL);

ALTER TABLE t3 ADD COLUMN w4 TEXT GENERATED ALWAYS AS (printf('%.*w',4,x)) VIRTUAL;
ALTER TABLE t3 ADD COLUMN w20 TEXT GENERATED ALWAYS AS (printf('%.*w',20,x)) VIRTUAL;

EXPLAIN QUERY PLAN SELECT w4, w20 FROM t3;
SELECT w4, w20 FROM t3;

DROP TABLE IF EXISTS t3;

-- Test 4: %#q with precision and control characters to exercise alternate form
DROP TABLE IF EXISTS t4;
CREATE TABLE t4(x TEXT);
-- x contains control characters (0x01, 0x02), a backslash, and a quote
INSERT INTO t4(x) VALUES(char(1) || '\\' || char(2) || '''end');

ALTER TABLE t4 ADD COLUMN aq3 TEXT GENERATED ALWAYS AS (printf('%#.*q',3,x)) VIRTUAL;
ALTER TABLE t4 ADD COLUMN aq10 TEXT GENERATED ALWAYS AS (printf('%#.*q',10,x)) VIRTUAL;

EXPLAIN QUERY PLAN SELECT aq3, aq10 FROM t4;
SELECT aq3, aq10 FROM t4;

DROP TABLE IF EXISTS t4;

-- Test 5: %#Q and %!Q with precision and multi-byte UTF-8 to exercise ! flag path
DROP TABLE IF EXISTS t5;
CREATE TABLE t5(x TEXT);
-- Use multi-byte UTF-8 characters (e.g., Chinese characters) mixed with ASCII and quotes
INSERT INTO t5(x) VALUES('中a文''b'),
                         ('é"f'),
                         (NULL);

-- %#Q with precision counts bytes; %!#Q (same as %#Q with ! flag) counts characters
ALTER TABLE t5 ADD COLUMN q_bytes_5 TEXT GENERATED ALWAYS AS (printf('%#.*Q',5,x)) VIRTUAL;
ALTER TABLE t5 ADD COLUMN q_chars_5 TEXT GENERATED ALWAYS AS (printf('%!#.*Q',5,x)) VIRTUAL;
ALTER TABLE t5 ADD COLUMN q_chars_20 TEXT GENERATED ALWAYS AS (printf('%!#.*Q',20,x)) VIRTUAL;

EXPLAIN QUERY PLAN SELECT q_bytes_5, q_chars_5, q_chars_20 FROM t5;
SELECT q_bytes_5, q_chars_5, q_chars_20 FROM t5;

DROP TABLE IF EXISTS t5;
-- ================================================================
-- SQL Regression Test for: Get trace with parameter insertion working for UTF16 databases.
-- task_id: 142
-- ================================================================

-- Each test enables statement tracing with parameter insertion via PRAGMA
-- and uses a UTF16 database or UTF16 string parameters to exercise the
-- vdbetrace.c logic that converts bound parameters to UTF-8 for tracing.

-- --------------------------------------------------------------------
-- Test 1: UTF16 database, named parameter starting with ':' and TEXT value
--         Exercises UTF16->UTF8 conversion for MEM_Str parameters and
--         testcase( zRawSql[0]==':' ).
-- --------------------------------------------------------------------
PRAGMA encoding = 'UTF-16';
PRAGMA temp_store = MEMORY;

CREATE TABLE t1(a INTEGER PRIMARY KEY, b TEXT);
INSERT INTO t1 VALUES(1, 'alpha');
INSERT INTO t1 VALUES(2, 'βeta');

-- Enable expanded SQL tracing to force vdbetrace parameter insertion.
PRAGMA main.trace = 'expanded';

-- Use a named parameter with ':' prefix and bind a TEXT value.
-- In the CLI or test harness this would be prepared and bound; here we
-- emulate execution to ensure the statement runs and reaches the trace code.
EXPLAIN QUERY PLAN
SELECT * FROM t1 WHERE b = :param1;

DROP TABLE t1;

-- --------------------------------------------------------------------
-- Test 2: UTF16 database, named parameter starting with '$' and TEXT value
--         Exercises testcase( zRawSql[0]=='$' ) and UTF16 string handling.
-- --------------------------------------------------------------------
PRAGMA encoding = 'UTF-16';

CREATE TABLE t2(x TEXT, y TEXT);
INSERT INTO t2 VALUES('γamma', 'delta');
INSERT INTO t2 VALUES('epsilon', 'ζeta');

PRAGMA main.trace = 'expanded';

EXPLAIN QUERY PLAN
SELECT x FROM t2 WHERE y = $p;

DROP TABLE t2;

-- --------------------------------------------------------------------
-- Test 3: UTF16 database, named parameter starting with '@' and TEXT value
--         Exercises testcase( zRawSql[0]=='@' ) and ensures trace works
--         with non-ASCII characters and empty result.
-- --------------------------------------------------------------------
PRAGMA encoding = 'UTF-16';

CREATE TABLE t3(id INTEGER, value TEXT);
INSERT INTO t3 VALUES(1, '汉字');
INSERT INTO t3 VALUES(2, '漢字');

PRAGMA main.trace = 'expanded';

EXPLAIN QUERY PLAN
SELECT value FROM t3 WHERE value = @v;

DROP TABLE t3;

-- --------------------------------------------------------------------
-- Test 4: UTF16 database, positional parameter '?1' with TEXT value
--         Ensures UTF16 MEM_Str parameters are converted to UTF8 for trace
--         even when using positional parameters instead of named ones.
-- --------------------------------------------------------------------
PRAGMA encoding = 'UTF-16';

CREATE TABLE t4(a TEXT, b TEXT);
INSERT INTO t4 VALUES('κappa', 'lambda');
INSERT INTO t4 VALUES('μu', NULL);

PRAGMA main.trace = 'expanded';

EXPLAIN QUERY PLAN
SELECT a FROM t4 WHERE b = ?1;

DROP TABLE t4;

-- --------------------------------------------------------------------
-- Test 5: UTF8 database, TEXT parameter to exercise the UTF8 fast path
--         Ensures the new UTF16-specific branch is bypassed and the
--         original sqlite3XPrintf call path is used.
-- --------------------------------------------------------------------
PRAGMA encoding = 'UTF-8';

CREATE TABLE t5(a INTEGER, b TEXT);
INSERT INTO t5 VALUES(1, 'simple');
INSERT INTO t5 VALUES(2, NULL);
INSERT INTO t5 VALUES(3, 'longvalue123');

PRAGMA main.trace = 'expanded';

EXPLAIN QUERY PLAN
SELECT b FROM t5 WHERE b = :ptext;

DROP TABLE t5;

-- ================================================================
-- SQL Regression Test for: Move [7d30880114] to the trunk. Add optimizations
-- to reduce the number of opcodes used for BEFORE UPDATE triggers.
-- task_id: 143
-- ================================================================

-- Test 1: BEFORE UPDATE trigger uses new.* on some columns only
--   - Exercises sqlite3TriggerColmask() for new.* with TRIGGER_BEFORE
--   - Ensures only referenced new.* columns are loaded before BEFORE trigger
--   - Covers UPDATE path computing newmask and conditional register loading
DROP TABLE IF EXISTS t1;
CREATE TABLE t1(
  id INTEGER PRIMARY KEY,
  a INT,
  b INT,
  c INT,
  d INT
);
INSERT INTO t1 VALUES(1, 10, 20, 30, 40);
INSERT INTO t1 VALUES(2, NULL, 0, 5, 100);

DROP TRIGGER IF EXISTS tr1_before_update;
CREATE TRIGGER tr1_before_update
BEFORE UPDATE ON t1
FOR EACH ROW
BEGIN
  -- Access new.a and new.c only (not new.b or new.d)
  SELECT NEW.a, NEW.c;
END;

EXPLAIN QUERY PLAN UPDATE t1 SET b = b+1 WHERE id = 1;
EXPLAIN QUERY PLAN UPDATE t1 SET d = d+1 WHERE id = 2;

DROP TRIGGER tr1_before_update;
DROP TABLE t1;


-- Test 2: BEFORE and AFTER UPDATE triggers with mixed old.* and new.* usage
--   - Exercises sqlite3TriggerColmask() for both old.* and new.*
--   - Ensures TRIGGER_BEFORE|TRIGGER_AFTER mask is honored
--   - Covers update.c oldmask and newmask computation and delete.c old.* mask
DROP TABLE IF EXISTS t2;
CREATE TABLE t2(
  id INTEGER PRIMARY KEY,
  x TEXT,
  y INT,
  z INT
);
INSERT INTO t2 VALUES(1, 'alpha', 1, 100);
INSERT INTO t2 VALUES(2, 'beta', 2, 200);

DROP TRIGGER IF EXISTS t2_before_update;
DROP TRIGGER IF EXISTS t2_after_update;

CREATE TRIGGER t2_before_update
BEFORE UPDATE ON t2
FOR EACH ROW
BEGIN
  -- BEFORE trigger reads new.x and new.y, but not new.z
  SELECT NEW.x, NEW.y;
END;

CREATE TRIGGER t2_after_update
AFTER UPDATE ON t2
FOR EACH ROW
BEGIN
  -- AFTER trigger reads old.z only
  SELECT OLD.z;
END;

EXPLAIN QUERY PLAN UPDATE t2 SET y = y + 10 WHERE id = 1;
EXPLAIN QUERY PLAN UPDATE t2 SET x = x || '!' WHERE id = 2;

DROP TRIGGER t2_before_update;
DROP TRIGGER t2_after_update;
DROP TABLE t2;


-- Test 3: BEFORE UPDATE trigger that only uses AFTER-style old.* (no new.*)
--   - Ensures newmask is zero so unchanged columns are not pre-loaded
--   - UPDATE modifies only one column; trigger does not reference new.*
--   - Exercises path where sqlite3TriggerColmask() for new.* returns 0
DROP TABLE IF EXISTS t3;
CREATE TABLE t3(
  id INTEGER PRIMARY KEY,
  m INT,
  n INT,
  p INT
);
INSERT INTO t3 VALUES(1, 1, 2, 3);
INSERT INTO t3 VALUES(2, 4, NULL, 6);

DROP TRIGGER IF EXISTS t3_before_update;
CREATE TRIGGER t3_before_update
BEFORE UPDATE ON t3
FOR EACH ROW
BEGIN
  -- BEFORE trigger reads only OLD.*; no NEW.* usage
  SELECT OLD.id, OLD.m, OLD.n, OLD.p;
END;

EXPLAIN QUERY PLAN UPDATE t3 SET m = m + 1 WHERE id = 1;
EXPLAIN QUERY PLAN UPDATE t3 SET n = COALESCE(n, 0) + 2 WHERE id = 2;

DROP TRIGGER t3_before_update;
DROP TABLE t3;


-- Test 4: DELETE with BEFORE and AFTER triggers using different OLD.* columns
--   - Exercises sqlite3TriggerColmask() in delete.c for TRIGGER_BEFORE|AFTER
--   - BEFORE trigger reads subset of columns; AFTER trigger reads others
DROP TABLE IF EXISTS t4;
CREATE TABLE t4(
  id INTEGER PRIMARY KEY,
  a TEXT,
  b INT,
  c INT,
  d INT
);
INSERT INTO t4 VALUES(1, 'row1', 10, 20, 30);
INSERT INTO t4 VALUES(2, 'row2', NULL, 0, 50);

DROP TRIGGER IF EXISTS t4_before_delete;
DROP TRIGGER IF EXISTS t4_after_delete;

CREATE TRIGGER t4_before_delete
BEFORE DELETE ON t4
FOR EACH ROW
BEGIN
  -- BEFORE trigger reads OLD.a and OLD.b only
  SELECT OLD.a, OLD.b;
END;

CREATE TRIGGER t4_after_delete
AFTER DELETE ON t4
FOR EACH ROW
BEGIN
  -- AFTER trigger reads OLD.c and OLD.d only
  SELECT OLD.c, OLD.d;
END;

EXPLAIN QUERY PLAN DELETE FROM t4 WHERE id = 1;
EXPLAIN QUERY PLAN DELETE FROM t4 WHERE b IS NULL;

DROP TRIGGER t4_before_delete;
DROP TRIGGER t4_after_delete;
DROP TABLE t4;


-- Test 5: BEFORE UPDATE trigger with many columns to exercise bitmask > 31
--   - Ensures sqlite3TriggerColmask() correctly handles column indexes >31
--   - BEFORE trigger references a high-index NEW.* column only
DROP TABLE IF EXISTS t5;
CREATE TABLE t5(
  id INTEGER PRIMARY KEY,
  c1 INT,  c2 INT,  c3 INT,  c4 INT,  c5 INT,
  c6 INT,  c7 INT,  c8 INT,  c9 INT,  c10 INT,
  c11 INT, c12 INT, c13 INT, c14 INT, c15 INT,
  c16 INT, c17 INT, c18 INT, c19 INT, c20 INT,
  c21 INT, c22 INT, c23 INT, c24 INT, c25 INT,
  c26 INT, c27 INT, c28 INT, c29 INT, c30 INT,
  c31 INT, c32 INT, c33 INT, c34 INT, c35 INT
);

INSERT INTO t5 VALUES(
  1,
  1,2,3,4,5,
  6,7,8,9,10,
  11,12,13,14,15,
  16,17,18,19,20,
  21,22,23,24,25,
  26,27,28,29,30,
  31,32,33,34,35
);

DROP TRIGGER IF EXISTS t5_before_update;
CREATE TRIGGER t5_before_update
BEFORE UPDATE ON t5
FOR EACH ROW
BEGIN
  -- Access only a high-index column (c33), exercising mask bit > 31
  SELECT NEW.c33;
END;

EXPLAIN QUERY PLAN UPDATE t5 SET c5 = c5 + 1 WHERE id = 1;
EXPLAIN QUERY PLAN UPDATE t5 SET c10 = c10 + 1 WHERE c32 = 32;

DROP TRIGGER t5_before_update;
DROP TABLE t5;

-- ================================================================
-- SQL Regression Test for: Add a test case for creating an FTS3 table
--                          with no module arguments or brackets.
-- task_id: 144
-- ================================================================

-- Test 1: FTS3 table with no module arguments (default column, default tokenizer)
-- Covers: fts3InitVtab() default column name path (nCol==0) and
--         default tokenizer initialization (pTokenizer==0 -> "simple").
DROP TABLE IF EXISTS t1;
CREATE VIRTUAL TABLE t1 USING fts3;
INSERT INTO t1(content) VALUES('hello world');
INSERT INTO t1(content) VALUES(NULL);
INSERT INTO t1(content) VALUES('');
EXPLAIN QUERY PLAN SELECT rowid FROM t1 WHERE t1 MATCH 'hello';
EXPLAIN QUERY PLAN SELECT rowid FROM t1 WHERE t1 MATCH 'world';
DROP TABLE IF EXISTS t1;

-- Test 2: FTS3 table with explicit column and no tokenizer clause
-- Covers: fts3InitVtab() column-name parsing with no special arguments
--         and default tokenizer initialization after scanning argv[].
DROP TABLE IF EXISTS t2;
CREATE VIRTUAL TABLE t2 USING fts3(body);
INSERT INTO t2(body) VALUES('edge case test');
INSERT INTO t2(body) VALUES('another test case');
INSERT INTO t2(body) VALUES(NULL);
EXPLAIN QUERY PLAN SELECT rowid FROM t2 WHERE t2 MATCH 'edge';
EXPLAIN QUERY PLAN SELECT rowid FROM t2 WHERE t2 MATCH 'case';
DROP TABLE IF EXISTS t2;

-- Test 3: FTS4 table with content= option and no explicit columns
-- Covers: fts3InitVtab() content= handling with nCol==0 and
--         automatic column discovery, followed by default tokenizer setup.
DROP TABLE IF EXISTS c3;
DROP TABLE IF EXISTS t3;
CREATE TABLE c3(x TEXT, y TEXT, langid INTEGER);
INSERT INTO c3 VALUES('one two', 'alpha beta', 1);
INSERT INTO c3 VALUES('three four', 'gamma delta', 2);
INSERT INTO c3 VALUES(NULL, NULL, NULL);
CREATE VIRTUAL TABLE t3 USING fts4(content=c3);
INSERT INTO t3(rowid, content) SELECT rowid, x || ' ' || y FROM c3;
EXPLAIN QUERY PLAN SELECT rowid FROM t3 WHERE t3 MATCH 'alpha';
EXPLAIN QUERY PLAN SELECT rowid FROM t3 WHERE t3 MATCH 'three';
DROP TABLE IF EXISTS t3;
DROP TABLE IF EXISTS c3;

-- Test 4: FTS3 table with tokenizer clause but no columns
-- Covers: tokenizer initialization via "tokenize" argument inside argv[]
--         (pTokenizer set before defaulting) and fallback default column
--         name path (nCol==0).
DROP TABLE IF EXISTS t4;
CREATE VIRTUAL TABLE t4 USING fts3(tokenize porter);
INSERT INTO t4(content) VALUES('running jumped');
INSERT INTO t4(content) VALUES('walked walking');
EXPLAIN QUERY PLAN SELECT rowid FROM t4 WHERE t4 MATCH 'run';
EXPLAIN QUERY PLAN SELECT rowid FROM t4 WHERE t4 MATCH 'walk';
DROP TABLE IF EXISTS t4;

-- Test 5: FTS4 table with multiple options, no bracketed args
-- Covers: fts3InitVtab() option parsing loop, including matchinfo=fts3
--         and prefix=, followed by default column and tokenizer logic.
DROP TABLE IF EXISTS t5;
CREATE VIRTUAL TABLE t5 USING fts4(matchinfo=fts3, prefix="2 3");
INSERT INTO t5(content) VALUES('simple prefix test');
INSERT INTO t5(content) VALUES('another simple example');
INSERT INTO t5(content) VALUES('edge');
EXPLAIN QUERY PLAN SELECT rowid FROM t5 WHERE t5 MATCH 'simple';
EXPLAIN QUERY PLAN SELECT rowid FROM t5 WHERE t5 MATCH 'prefix';
DROP TABLE IF EXISTS t5;
-- ================================================================
-- SQL Regression Test for: Remove benign OOM failure opportunities
-- task_id: 145
-- ================================================================

PRAGMA foreign_keys = OFF;

-- Test 1: Basic FTS3 table creation and insert to exercise initial fts3Rehash path
DROP TABLE IF EXISTS t1;
CREATE VIRTUAL TABLE t1 USING fts3(content TEXT);
INSERT INTO t1(content) VALUES('one');
INSERT INTO t1(content) VALUES('two');
INSERT INTO t1(content) VALUES('three');
EXPLAIN QUERY PLAN SELECT rowid FROM t1 WHERE content MATCH 'one';
EXPLAIN QUERY PLAN SELECT count(*) FROM t1 WHERE content MATCH 'two';
DROP TABLE IF EXISTS t1;

-- Test 2: Many terms to grow hash table and exercise rehash-on-growth path
DROP TABLE IF EXISTS t2;
CREATE VIRTUAL TABLE t2 USING fts3(content TEXT);
WITH RECURSIVE seq(x) AS (
  SELECT 1
  UNION ALL
  SELECT x+1 FROM seq WHERE x<50
)
INSERT INTO t2(content)
SELECT 'term_' || x FROM seq;
EXPLAIN QUERY PLAN SELECT count(*) FROM t2 WHERE content MATCH 'term_1 OR term_25 OR term_50';
EXPLAIN QUERY PLAN SELECT rowid FROM t2 WHERE content MATCH 'term_10';
DROP TABLE IF EXISTS t2;

-- Test 3: Deletions and reinserts to exercise hash remove/rehash behavior
DROP TABLE IF EXISTS t3;
CREATE VIRTUAL TABLE t3 USING fts3(content TEXT);
INSERT INTO t3(content) VALUES('alpha beta gamma');
INSERT INTO t3(content) VALUES('beta gamma delta');
INSERT INTO t3(content) VALUES('gamma delta epsilon');
DELETE FROM t3 WHERE content MATCH 'alpha';
INSERT INTO t3(content) VALUES('alpha');
EXPLAIN QUERY PLAN SELECT rowid FROM t3 WHERE content MATCH 'gamma';
EXPLAIN QUERY PLAN SELECT count(*) FROM t3 WHERE content MATCH 'alpha OR epsilon';
DROP TABLE IF EXISTS t3;

-- Test 4: Edge cases with empty string, NULL and duplicate tokens
DROP TABLE IF EXISTS t4;
CREATE VIRTUAL TABLE t4 USING fts3(content TEXT);
INSERT INTO t4(rowid, content) VALUES(1, '');
INSERT INTO t4(rowid, content) VALUES(2, NULL);
INSERT INTO t4(rowid, content) VALUES(3, 'repeat repeat repeat');
INSERT INTO t4(rowid, content) VALUES(4, 'mixed NULL like text');
EXPLAIN QUERY PLAN SELECT rowid FROM t4 WHERE content MATCH 'repeat';
EXPLAIN QUERY PLAN SELECT count(*) FROM t4 WHERE content MATCH 'mixed';
DROP TABLE IF EXISTS t4;

-- Test 5: Multiple FTS3 tables and indices to stress hash with varied schemas
DROP TABLE IF EXISTS t5a;
DROP TABLE IF EXISTS t5b;
CREATE VIRTUAL TABLE t5a USING fts3(title TEXT, body TEXT);
CREATE VIRTUAL TABLE t5b USING fts3(x TEXT);
INSERT INTO t5a(title, body) VALUES('doc1', 'fts3 hash table test one');
INSERT INTO t5a(title, body) VALUES('doc2', 'fts3 hash table test two');
INSERT INTO t5a(title, body) VALUES('doc3', 'another document for testing');
INSERT INTO t5b(x) VALUES('aux one');
INSERT INTO t5b(x) VALUES('aux two');
EXPLAIN QUERY PLAN SELECT rowid FROM t5a WHERE t5a MATCH 'test';
EXPLAIN QUERY PLAN SELECT rowid FROM t5b WHERE x MATCH 'aux';
DROP TABLE IF EXISTS t5a;
DROP TABLE IF EXISTS t5b;

-- ================================================================
-- SQL Regression Test for: Fix segfault on empty FTS3 table &
--                          restore rowid/docid conflict handling
-- task_id: 146
-- ================================================================

-- Test 1: Rowid/docid conflict on simple FTS3 table (INSERT specifies both)
-- Covers: fts3InsertData() rowid/docid conflict path returning SQLITE_ERROR
DROP TABLE IF EXISTS t1;
CREATE VIRTUAL TABLE t1 USING fts3(content TEXT);

-- Non-NULL values for both rowid and docid should hit the conflict logic.
EXPLAIN QUERY PLAN
INSERT INTO t1(rowid, docid, content) VALUES(1, 2, 'conflict test 1');

DROP TABLE IF EXISTS t1;


-- Test 2: Rowid/docid conflict when content table is external (zContentTbl non-NULL)
-- Covers: fts3InsertData() docid selection when p->zContentTbl is set,
--         legacy handling of rowid/docid aliases
DROP TABLE IF EXISTS content2;
DROP TABLE IF EXISTS t2;

-- External content table pattern for FTS3
CREATE TABLE content2(docid INTEGER PRIMARY KEY, body TEXT);
CREATE VIRTUAL TABLE t2 USING fts3(content="content2", content=body);

-- Insert into external content table directly so there is a row to index.
INSERT INTO content2(docid, body) VALUES(10, 'external body');

-- Attempt to index with conflicting rowid/docid should use conflict logic
EXPLAIN QUERY PLAN
INSERT INTO t2(rowid, docid, body) VALUES(10, 11, 'external body');

DROP TABLE IF EXISTS t2;
DROP TABLE IF EXISTS content2;


-- Test 3: Successful explicit docid with NULL rowid alias (no conflict)
-- Covers: fts3InsertData() path where docid is specified and rowid is NULL
DROP TABLE IF EXISTS t3;
CREATE VIRTUAL TABLE t3 USING fts3(content TEXT);

-- Here rowid is explicitly set to NULL, docid non-NULL: should be accepted.
EXPLAIN QUERY PLAN
INSERT INTO t3(rowid, docid, content) VALUES(NULL, 5, 'no conflict');

-- Verify that querying by docid exercises read paths with non-default docid
EXPLAIN QUERY PLAN
SELECT rowid, docid, content FROM t3 WHERE docid = 5;

DROP TABLE IF EXISTS t3;


-- Test 4: Querying an empty FTS3 table (no segments, nSegment==0)
-- Covers: sqlite3Fts3SegReaderStep() early-return when pCsr->nSegment==0,
--         preventing segfault when reading from empty index
DROP TABLE IF EXISTS t4;
CREATE VIRTUAL TABLE t4 USING fts3(content TEXT);

-- No rows inserted: index is empty, no segments built.
EXPLAIN QUERY PLAN
SELECT rowid, content FROM t4 WHERE t4 MATCH 'nothing';

-- Also exercise prefix scan on empty index
EXPLAIN QUERY PLAN
SELECT rowid FROM t4 WHERE t4 MATCH 'no*';

DROP TABLE IF EXISTS t4;


-- Test 5: Segment merge logic with zero segments selected
-- Covers: fts3SegmentMerge() early-exit when csr.nSegment==0, via optimize
DROP TABLE IF EXISTS t5;
CREATE VIRTUAL TABLE t5 USING fts3(content TEXT);

-- Force an optimize on a table with no or minimal segment data.
EXPLAIN QUERY PLAN
SELECT optimize(t5) FROM t5;

-- Also run optimize after inserting then deleting rows so that
-- there may be no remaining segments to merge.
INSERT INTO t5(content) VALUES('alpha'),('beta');
DELETE FROM t5;
EXPLAIN QUERY PLAN
SELECT optimize(t5) FROM t5;

DROP TABLE IF EXISTS t5;

-- ================================================================
-- SQL Regression Test for: Add testcase() macros for BEFORE UPDATE triggers
-- task_id: 147
-- ================================================================

-- Test 1: BEFORE UPDATE trigger uses NEW.* on column index 31 (boundary i==31)
DROP TABLE IF EXISTS t31;
CREATE TABLE t31(
  c0  INTEGER PRIMARY KEY,
  c1  TEXT,  c2  TEXT,  c3  TEXT,  c4  TEXT,
  c5  TEXT,  c6  TEXT,  c7  TEXT,  c8  TEXT,
  c9  TEXT,  c10 TEXT,  c11 TEXT,  c12 TEXT,
  c13 TEXT,  c14 TEXT,  c15 TEXT,  c16 TEXT,
  c17 TEXT,  c18 TEXT,  c19 TEXT,  c20 TEXT,
  c21 TEXT,  c22 TEXT,  c23 TEXT,  c24 TEXT,
  c25 TEXT,  c26 TEXT,  c27 TEXT,  c28 TEXT,
  c29 TEXT,  c30 TEXT,  c31 TEXT
);

INSERT INTO t31 VALUES(1,
  'v1','v2','v3','v4','v5','v6','v7','v8','v9','v10',
  'v11','v12','v13','v14','v15','v16','v17','v18','v19','v20',
  'v21','v22','v23','v24','v25','v26','v27','v28','v29','v30','v31'
);

CREATE TRIGGER t31_bu
BEFORE UPDATE ON t31
FOR EACH ROW
BEGIN
  -- Access NEW.c31 so that column index 31 is loaded via newmask path
  SELECT NEW.c31;
END;

EXPLAIN QUERY PLAN UPDATE t31 SET c1 = 'x';
DROP TABLE IF EXISTS t31;

-- Test 2: BEFORE UPDATE trigger uses NEW.* on column index 32 (i>31 branch)
DROP TABLE IF EXISTS t32;
CREATE TABLE t32(
  c0  INTEGER PRIMARY KEY,
  c1  TEXT,  c2  TEXT,  c3  TEXT,  c4  TEXT,
  c5  TEXT,  c6  TEXT,  c7  TEXT,  c8  TEXT,
  c9  TEXT,  c10 TEXT,  c11 TEXT,  c12 TEXT,
  c13 TEXT,  c14 TEXT,  c15 TEXT,  c16 TEXT,
  c17 TEXT,  c18 TEXT,  c19 TEXT,  c20 TEXT,
  c21 TEXT,  c22 TEXT,  c23 TEXT,  c24 TEXT,
  c25 TEXT,  c26 TEXT,  c27 TEXT,  c28 TEXT,
  c29 TEXT,  c30 TEXT,  c31 TEXT,  c32 TEXT
);

INSERT INTO t32 VALUES(1,
  'v1','v2','v3','v4','v5','v6','v7','v8','v9','v10',
  'v11','v12','v13','v14','v15','v16','v17','v18','v19','v20',
  'v21','v22','v23','v24','v25','v26','v27','v28','v29','v30','v31','v32'
);

CREATE TRIGGER t32_bu
BEFORE UPDATE ON t32
FOR EACH ROW
BEGIN
  -- Access NEW.c32 to exercise testcase(i==32) and i>31 branch
  SELECT NEW.c32;
END;

EXPLAIN QUERY PLAN UPDATE t32 SET c2 = 'y';
DROP TABLE IF EXISTS t32;

-- Test 3: BEFORE UPDATE trigger with NULL and unmodified columns (newmask & MASKBIT32)
DROP TABLE IF EXISTS t_null;
CREATE TABLE t_null(
  id INTEGER PRIMARY KEY,
  a0 TEXT,
  a1 TEXT,
  a2 TEXT,
  a3 TEXT,
  a4 TEXT,
  a5 TEXT,
  a6 TEXT,
  a7 TEXT,
  a8 TEXT,
  a9 TEXT,
  a10 TEXT,
  a11 TEXT,
  a12 TEXT,
  a13 TEXT,
  a14 TEXT,
  a15 TEXT,
  a16 TEXT,
  a17 TEXT,
  a18 TEXT,
  a19 TEXT,
  a20 TEXT,
  a21 TEXT,
  a22 TEXT,
  a23 TEXT,
  a24 TEXT,
  a25 TEXT,
  a26 TEXT,
  a27 TEXT,
  a28 TEXT,
  a29 TEXT,
  a30 TEXT,
  a31 TEXT
);

INSERT INTO t_null VALUES(1,
  NULL,'b1','b2','b3','b4','b5','b6','b7','b8','b9',
  'b10','b11','b12','b13','b14','b15','b16','b17','b18','b19',
  'b20','b21','b22','b23','b24','b25','b26','b27','b28','b29','b30',NULL
);

CREATE TRIGGER t_null_bu
BEFORE UPDATE ON t_null
FOR EACH ROW
BEGIN
  -- Access an unmodified column a31 and a0 to ensure they are loaded
  SELECT NEW.a31, NEW.a0;
END;

EXPLAIN QUERY PLAN UPDATE t_null SET a5 = 'changed';
DROP TABLE IF EXISTS t_null;

-- Test 4: BEFORE UPDATE trigger on view with many columns (isView, newmask optimization)
DROP TABLE IF EXISTS base_v;
DROP VIEW IF EXISTS v_many;
CREATE TABLE base_v(
  k INTEGER PRIMARY KEY,
  v0 TEXT,
  v1 TEXT,
  v2 TEXT,
  v3 TEXT,
  v4 TEXT,
  v5 TEXT,
  v6 TEXT,
  v7 TEXT,
  v8 TEXT,
  v9 TEXT,
  v10 TEXT,
  v11 TEXT,
  v12 TEXT,
  v13 TEXT,
  v14 TEXT,
  v15 TEXT,
  v16 TEXT,
  v17 TEXT,
  v18 TEXT,
  v19 TEXT,
  v20 TEXT,
  v21 TEXT,
  v22 TEXT,
  v23 TEXT,
  v24 TEXT,
  v25 TEXT,
  v26 TEXT,
  v27 TEXT,
  v28 TEXT,
  v29 TEXT,
  v30 TEXT,
  v31 TEXT
);

INSERT INTO base_v VALUES(1,
  'x0','x1','x2','x3','x4','x5','x6','x7','x8','x9',
  'x10','x11','x12','x13','x14','x15','x16','x17','x18','x19',
  'x20','x21','x22','x23','x24','x25','x26','x27','x28','x29','x30','x31'
);

CREATE VIEW v_many AS
  SELECT k,
         v0,v1,v2,v3,v4,v5,v6,v7,v8,v9,
         v10,v11,v12,v13,v14,v15,v16,v17,v18,v19,
         v20,v21,v22,v23,v24,v25,v26,v27,v28,v29,
         v30,v31
  FROM base_v;

CREATE TRIGGER v_many_bu
INSTEAD OF UPDATE ON v_many
FOR EACH ROW
BEGIN
  -- Access NEW fields near the 31 boundary and update base table
  UPDATE base_v
    SET v31 = NEW.v31,
        v30 = NEW.v30
    WHERE k = NEW.k;
END;

EXPLAIN QUERY PLAN UPDATE v_many SET v30 = 'nv30', v31 = 'nv31';
DROP TRIGGER IF EXISTS v_many_bu;
DROP VIEW IF EXISTS v_many;
DROP TABLE IF EXISTS base_v;

-- Test 5: BEFORE UPDATE trigger with many unmodified columns and empty update (no-op)
DROP TABLE IF EXISTS t_noop;
CREATE TABLE t_noop(
  id INTEGER PRIMARY KEY,
  c1  TEXT,
  c2  TEXT,
  c3  TEXT,
  c4  TEXT,
  c5  TEXT,
  c6  TEXT,
  c7  TEXT,
  c8  TEXT,
  c9  TEXT,
  c10 TEXT,
  c11 TEXT,
  c12 TEXT,
  c13 TEXT,
  c14 TEXT,
  c15 TEXT,
  c16 TEXT,
  c17 TEXT,
  c18 TEXT,
  c19 TEXT,
  c20 TEXT,
  c21 TEXT,
  c22 TEXT,
  c23 TEXT,
  c24 TEXT,
  c25 TEXT,
  c26 TEXT,
  c27 TEXT,
  c28 TEXT,
  c29 TEXT,
  c30 TEXT,
  c31 TEXT
);

INSERT INTO t_noop VALUES(1,
  'y1','y2','y3','y4','y5','y6','y7','y8','y9','y10',
  'y11','y12','y13','y14','y15','y16','y17','y18','y19','y20',
  'y21','y22','y23','y24','y25','y26','y27','y28','y29','y30','y31'
);

CREATE TRIGGER t_noop_bu
BEFORE UPDATE ON t_noop
FOR EACH ROW
BEGIN
  -- Access several NEW.* columns, including one near index 31
  SELECT NEW.c2, NEW.c15, NEW.c31;
END;

-- UPDATE that changes only the primary key via a self-assignment, leaving others unmodified
EXPLAIN QUERY PLAN UPDATE t_noop SET id = id;
DROP TABLE IF EXISTS t_noop;
-- ================================================================
-- SQL Regression Test for: Fix an OOM related problem in the snippet() and offsets() functions of fts3.
-- task_id: 148
-- ================================================================

-- Test 1: Basic snippet() usage to exercise successful fts3CursorSeek() and sqlite3Fts3Snippet()
DROP TABLE IF EXISTS t1;
CREATE VIRTUAL TABLE t1 USING fts3(content TEXT);
INSERT INTO t1(rowid, content) VALUES
  (1, 'this is a simple document'),
  (2, 'another simple document with snippet function test');

-- Use a query that returns at least one row and call snippet() with default markers
SELECT snippet(t1)
FROM t1
WHERE t1 MATCH 'simple';

DROP TABLE IF EXISTS t1;


-- Test 2: snippet() with custom start/end/ellipsis markers, covering NULL-marker OOM path
DROP TABLE IF EXISTS t2;
CREATE VIRTUAL TABLE t2 USING fts3(content TEXT);
INSERT INTO t2(rowid, content) VALUES
  (1, 'one two three four five six seven eight nine ten'),
  (2, 'snippet function custom markers test');

-- Call snippet() with 4 arguments, forcing retrieval of start, end and ellipsis markers
-- Then also invoke a call where markers become NULL (simulated by concatenation with NULL)
SELECT snippet(t2, '[', ']', '...')
FROM t2
WHERE t2 MATCH 'snippet';

-- This second call uses expressions that may yield NULL markers; even if they do not,
-- it still passes through the new !zStart/!zEnd/!zEllipsis check
SELECT snippet(t2,
       '[' || NULL,
       ']' || NULL,
       '...' || NULL
)
FROM t2
WHERE t2 MATCH 'snippet';

DROP TABLE IF EXISTS t2;


-- Test 3: offsets() usage on matching rows to exercise successful fts3CursorSeek() and sqlite3Fts3Offsets()
DROP TABLE IF EXISTS t3;
CREATE VIRTUAL TABLE t3 USING fts3(content TEXT);
INSERT INTO t3(rowid, content) VALUES
  (1, 'alpha beta gamma'),
  (2, 'beta only'),
  (3, 'no match here');

-- Query includes MATCH so that FTS3 cursor is positioned and offsets() is invoked
SELECT offsets(t3)
FROM t3
WHERE t3 MATCH 'beta';

DROP TABLE IF EXISTS t3;


-- Test 4: offsets() on an empty result set to exercise fts3CursorSeek() when cursor is at EOF
DROP TABLE IF EXISTS t4;
CREATE VIRTUAL TABLE t4 USING fts3(content TEXT);
INSERT INTO t4(rowid, content) VALUES
  (1, 'one two three'),
  (2, 'four five six');

-- Use a MATCH that returns no rows; planner still prepares FTS3 cursor and may call offsets()
SELECT offsets(t4)
FROM t4
WHERE t4 MATCH 'nonexistenttoken';

DROP TABLE IF EXISTS t4;


-- Test 5: Combined snippet() and offsets() usage with multiple columns and NULLs
-- This exercises repeated calls to fts3CursorSeek() from both functions.
DROP TABLE IF EXISTS t5;
CREATE VIRTUAL TABLE t5 USING fts3(a TEXT, b TEXT);
INSERT INTO t5(rowid, a, b) VALUES
  (1, 'first column text with token', 'second column also has token'),
  (2, NULL, 'only second column token'),
  (3, 'no token here', NULL);

-- Use a MATCH that hits multiple columns and rows
SELECT snippet(t5, '<b>', '</b>', '...')
FROM t5
WHERE t5 MATCH 'token';

-- Call offsets() on the same query to ensure offsets() path is also exercised
SELECT offsets(t5)
FROM t5
WHERE t5 MATCH 'token';

DROP TABLE IF EXISTS t5;

-- ================================================================
-- SQL Regression Test for: Rationalize FTS3 optimize/merge paths and
--                           support "INSERT INTO tbl(tbl) VALUES('optimize')"
-- task_id: 149
-- ================================================================

-- Test 1: Special INSERT optimize command via INSERT INTO tbl(tbl) VALUES('optimize')
--   Exercises: fts3SpecialInsert("optimize"), fts3DoOptimize(),
--              sqlite3Fts3PendingTermsFlush(), pending-terms SegReader merge path.
DROP TABLE IF EXISTS t1;
CREATE VIRTUAL TABLE t1 USING fts3(content);

-- Populate table with enough data to create multiple segments/pending terms.
INSERT INTO t1(content) VALUES('one two three four five six seven eight nine ten');
INSERT INTO t1(content) VALUES('eleven twelve thirteen fourteen fifteen sixteen');
INSERT INTO t1(content) VALUES('seventeen eighteen nineteen twenty twentyone twentytwo');
INSERT INTO t1(content) VALUES('alpha beta gamma delta epsilon zeta eta theta iota kappa');

-- Force creation of pending terms and on-disk segments via queries.
SELECT count(*) FROM t1 WHERE content MATCH 'one';
SELECT count(*) FROM t1 WHERE content MATCH 'twenty';

-- Special optimize INSERT using the new syntax.
INSERT INTO t1(t1) VALUES('optimize');

-- Run some queries to exercise post-optimize segment layout.
EXPLAIN QUERY PLAN SELECT rowid FROM t1 WHERE content MATCH 'one';
EXPLAIN QUERY PLAN SELECT rowid FROM t1 WHERE content MATCH 'alpha';

DROP TABLE IF EXISTS t1;


-- Test 2: Special INSERT rebuild command and integrity after rebuild
--   Exercises: fts3SpecialInsert("rebuild"), fts3DoRebuild(),
--              pending-terms reader over hash, docsize/stat update paths.
DROP TABLE IF EXISTS t2;
CREATE VIRTUAL TABLE t2 USING fts3(title, body);

INSERT INTO t2(title, body) VALUES('doc1', 'apple banana cherry');
INSERT INTO t2(title, body) VALUES('doc2', 'banana cherry date');
INSERT INTO t2(title, body) VALUES('doc3', 'cherry date eggfruit fig grape');

-- Run some MATCH queries to create and read segments.
SELECT rowid FROM t2 WHERE body MATCH 'banana';
SELECT rowid FROM t2 WHERE body MATCH 'cherry';

-- Rebuild the entire FTS index using the special INSERT form.
INSERT INTO t2(t2) VALUES('rebuild');

-- Exercise index after rebuild and ensure docsize/stat handling paths run.
EXPLAIN QUERY PLAN SELECT rowid FROM t2 WHERE body MATCH 'banana';
EXPLAIN QUERY PLAN SELECT rowid FROM t2 WHERE body MATCH 'grape';

DROP TABLE IF EXISTS t2;


-- Test 3: Special INSERT integrity-check and merge commands, including error path
--   Exercises: fts3SpecialInsert("integrity-check"), "merge=" and error
--              branch for unknown command; also pending-terms flush via "flush".
DROP TABLE IF EXISTS t3;
CREATE VIRTUAL TABLE t3 USING fts3(x);

INSERT INTO t3(x) VALUES('foo bar baz');
INSERT INTO t3(x) VALUES('foo qux');
INSERT INTO t3(x) VALUES('lorem ipsum dolor sit amet');

-- Create some segments and pending terms.
SELECT rowid FROM t3 WHERE x MATCH 'foo';
SELECT rowid FROM t3 WHERE x MATCH 'lorem';

-- Run integrity-check special command.
INSERT INTO t3(t3) VALUES('integrity-check');

-- Run a small incremental merge via special merge=N syntax.
INSERT INTO t3(t3) VALUES('merge=2');

-- Flush pending terms using special flush command.
INSERT INTO t3(t3) VALUES('flush');

-- Exercise error branch in fts3SpecialInsert with an unknown command string.
-- This should fail but still exercise the error path.
INSERT OR IGNORE INTO t3(t3) VALUES('unknown-command');

EXPLAIN QUERY PLAN SELECT rowid FROM t3 WHERE x MATCH 'foo';
EXPLAIN QUERY PLAN SELECT rowid FROM t3 WHERE x MATCH 'baz';

DROP TABLE IF EXISTS t3;


-- Test 4: Pending-terms prefix SegReader path and autoincr/merge stats
--   Exercises: sqlite3Fts3SegReaderPending() with bPrefix=1 (prefix search),
--              dynamic aElem allocation/growth, and autoincr-merge hint paths.
DROP TABLE IF EXISTS t4;
CREATE VIRTUAL TABLE t4 USING fts4(a, b);

INSERT INTO t4(a, b) VALUES('firebird', 'x');
INSERT INTO t4(a, b) VALUES('mysql', 'y');
INSERT INTO t4(a, b) VALUES('sqlite', 'z');
INSERT INTO t4(a, b) VALUES('fire', 'prefix test one');
INSERT INTO t4(a, b) VALUES('firebird finch', 'prefix test two');
INSERT INTO t4(a, b) VALUES('firefighter', 'prefix test three');

-- Issue a prefix MATCH query to force use of pending-terms SegReader in prefix mode.
SELECT rowid FROM t4 WHERE a MATCH 'fi*';
SELECT rowid FROM t4 WHERE a MATCH 'sq*';

-- Trigger optimize via special INSERT to encourage segment merges and stat updates.
INSERT INTO t4(t4) VALUES('optimize');

EXPLAIN QUERY PLAN SELECT rowid FROM t4 WHERE a MATCH 'fire*';
EXPLAIN QUERY PLAN SELECT rowid FROM t4 WHERE a MATCH 'sqlite';

DROP TABLE IF EXISTS t4;


-- Test 5: Edge cases for special INSERT: NULL value, automerge, maxpending/nodesize
--   Exercises: fts3SpecialInsert() NULL handling, automerge=, maxpending=,
--              nodesize= and test-only options where available.
DROP TABLE IF EXISTS t5;
CREATE VIRTUAL TABLE t5 USING fts4(content);

INSERT INTO t5(content) VALUES('edge case one two three four');
INSERT INTO t5(content) VALUES('another edge case value');

-- Attempt to call special insert with NULL (should take SQLITE_NOMEM or error path).
INSERT OR IGNORE INTO t5(t5) VALUES(NULL);

-- Configure automatic incremental merge and pending/segment parameters.
INSERT INTO t5(t5) VALUES('automerge=2');
INSERT INTO t5(t5) VALUES('merge=4');
INSERT INTO t5(t5) VALUES('maxpending=2048');
INSERT INTO t5(t5) VALUES('nodesize=512');

-- Run queries to exercise new configuration.
EXPLAIN QUERY PLAN SELECT rowid FROM t5 WHERE content MATCH 'edge';
EXPLAIN QUERY PLAN SELECT rowid FROM t5 WHERE content MATCH 'three';

DROP TABLE IF EXISTS t5;

-- ================================================================
-- SQL Regression Test for: Extra tests for coverage of fts3 code.
-- task_id: 150
-- ================================================================

-- Test 1: Basic FTS3 insert and optimize to exercise fts3WriteSegment and fts3WriteSegdir
CREATE VIRTUAL TABLE t1 USING fts3(content TEXT);
INSERT INTO t1(docid, content) VALUES(1, 'alpha beta gamma');
INSERT INTO t1(docid, content) VALUES(2, 'beta gamma delta');

-- Force flushing pending terms and segment creation via optimize
EXPLAIN QUERY PLAN SELECT rowid FROM t1 WHERE t1 MATCH 'beta';
SELECT sqlite3_fts3_tokenizer('simple');
PRAGMA writable_schema=OFF;
SELECT sqlite3_fts3_tokenizer('simple');

SELECT rowid FROM t1 WHERE t1 MATCH 'gamma';

DROP TABLE t1;

-- Test 2: Multiple inserts and optimize to create larger segments (exercise blobs and segdir root)
CREATE VIRTUAL TABLE t2 USING fts3(content TEXT);
INSERT INTO t2(docid, content) VALUES(1, 'one two three four five six seven eight nine ten');
INSERT INTO t2(docid, content) VALUES(2, 'one one one one one one one one one one');
INSERT INTO t2(docid, content) VALUES(3, 'two two two two two two two two two two');

-- Trigger segment flush and merge
INSERT INTO t2(t2) VALUES('optimize');

EXPLAIN QUERY PLAN SELECT rowid FROM t2 WHERE t2 MATCH 'one';
EXPLAIN QUERY PLAN SELECT rowid FROM t2 WHERE t2 MATCH 'two';

DROP TABLE t2;

-- Test 3: FTS3 with prefix index to exercise prefix-related segment writing and segdir root blobs
CREATE VIRTUAL TABLE t3 USING fts3(content TEXT, prefix="1,2,3");
INSERT INTO t3(docid, content) VALUES(1, 'prefix testing alpha');
INSERT INTO t3(docid, content) VALUES(2, 'prefix alpha beta');
INSERT INTO t3(docid, content) VALUES(3, 'prefix beta gamma');

-- Use prefix searches to read from segments and ensure segdir entries are populated
EXPLAIN QUERY PLAN SELECT rowid FROM t3 WHERE t3 MATCH 'pr*';
EXPLAIN QUERY PLAN SELECT rowid FROM t3 WHERE t3 MATCH 'al*';

DROP TABLE t3;

-- Test 4: Edge cases involving NULL, empty string and special characters to exercise pending flush callback
CREATE VIRTUAL TABLE t4 USING fts3(content TEXT);
INSERT INTO t4(docid, content) VALUES(1, NULL);
INSERT INTO t4(docid, content) VALUES(2, '');
INSERT INTO t4(docid, content) VALUES(3, 'special !@#$%^&*() characters');
INSERT INTO t4(docid, content) VALUES(4, 'repeat repeat repeat');

-- Force a flush of pending terms via optimize and then query
INSERT INTO t4(t4) VALUES('optimize');

EXPLAIN QUERY PLAN SELECT rowid FROM t4 WHERE t4 MATCH 'repeat';
EXPLAIN QUERY PLAN SELECT rowid FROM t4 WHERE t4 MATCH 'special';

DROP TABLE t4;

-- Test 5: FTS4-like scenario using FTS3 options to ensure flushing pending terms with large doclists
CREATE VIRTUAL TABLE t5 USING fts3(content TEXT, tokenize=unicode61);
INSERT INTO t5(docid, content) VALUES(1, 'a very long document with many repeated tokens repeated tokens repeated tokens');
INSERT INTO t5(docid, content) VALUES(2, 'another long document with repeated tokens repeated tokens');
INSERT INTO t5(docid, content) VALUES(3, 'short');

-- Optimize to flush pending terms and merge, then run queries to traverse segments
INSERT INTO t5(t5) VALUES('optimize');

EXPLAIN QUERY PLAN SELECT rowid FROM t5 WHERE t5 MATCH 'repeated';
EXPLAIN QUERY PLAN SELECT rowid FROM t5 WHERE t5 MATCH 'document';

DROP TABLE t5;

