-- Clear last week's testing before the public link (M6). Asked for by Max on
-- 2026-10-12: the reports and timers from Oct 8-9 were his own testing, but his
-- ID was not in test_anon_ids, so they counted as real and showed in History.
--
-- Everything created before midnight Eastern starting Oct 12 is deleted, as in
-- the 2026-10-08 fresh start (20261008190000_fresh_start.sql). Rows from Oct 12
-- on stay, since they may be real beta testers from the public link (on the
-- 2026-10-12 data check: 2 installs and 34 views, no reports, timers, or
-- feedback). Bars, settings, the settings log, and event nights stay. In a
-- fresh database this deletes nothing.
--
-- No table, field, function, or answer-code change.

-- No triggers fire on these tables (only app.config has triggers), so nothing
-- is logged or written elsewhere. Reports go before wait sessions, which they
-- reference. No other table references installs.
delete from app.rate_limit_holds   where created_at < '2026-10-12 00:00 America/New_York';
delete from app.deletions          where created_at < '2026-10-12 00:00 America/New_York';
delete from app.spot_checks        where created_at < '2026-10-12 00:00 America/New_York';
delete from app.estimate_snapshots where created_at < '2026-10-12 00:00 America/New_York';
delete from app.feedback           where created_at < '2026-10-12 00:00 America/New_York';
delete from app.views              where created_at < '2026-10-12 00:00 America/New_York';
delete from app.reports            where created_at < '2026-10-12 00:00 America/New_York';
delete from app.wait_sessions      where created_at < '2026-10-12 00:00 America/New_York';
delete from app.installs           where created_at < '2026-10-12 00:00 America/New_York';
