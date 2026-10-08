-- Fresh start before the field test (M5). Asked for by Max on 2026-10-08:
-- everything so far was his own testing, so it is deleted rather than marked
-- is_test.
--
-- Every report, wait, install, view, feedback row, snapshot, spot check,
-- deletion count, and rate-limit hold is deleted, as in the 2026-10-06 wipe
-- (20261007120000_line_sizes_no_crowd.sql). Bars, settings (including
-- test_anon_ids), the settings log, and event nights stay. In a fresh database
-- this deletes nothing.
--
-- No table, field, function, or answer-code change.

-- No triggers fire on these tables (only app.config has triggers), so nothing
-- is logged or written elsewhere. Reports go before wait sessions, which they
-- reference.
delete from app.rate_limit_holds;
delete from app.deletions;
delete from app.spot_checks;
delete from app.estimate_snapshots;
delete from app.feedback;
delete from app.views;
delete from app.reports;
delete from app.wait_sessions;
delete from app.installs;
