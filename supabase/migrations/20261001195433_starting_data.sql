-- Default settings and the three starting bars.
--
-- This is a migration, not seed.sql, because seed.sql only runs on local
-- resets and the live project needs this data too. Change these values later
-- in the dashboard (Table Editor > app.config); each change is logged in
-- app.config_history.

insert into app.config (key, value, description) values
  ('fresh_minutes',           '30',        'Reports are fresh for this many minutes (FR-17).'),
  ('stale_minutes',           '60',        'Reports older than fresh_minutes show grayed out until this age, then "Not enough data" (FR-17).'),
  ('agree_within',            '1',         'Two answers agree when their codes are at most this far apart (FR-19).'),
  ('majority_min_others',     '2',         'The majority wins when the newest report disagrees with this many fresh reports from other people (FR-19).'),
  ('rate_limit_minutes',      '10',        'One report per bar per person in this many minutes (FR-13).'),
  ('session_timeout_minutes', '90',        'Open wait sessions become unfinished after this many minutes (FR-10).'),
  ('uncertain_distance_m',    '150',       'Reports farther than this from the door are uncertain (FR-27).'),
  ('uncertain_accuracy_m',    '100',       'Reports with GPS accuracy worse than this are uncertain (FR-27).'),
  ('uncertain_fix_age_s',     '120',       'Reports with a location fix older than this are uncertain (FR-27).'),
  ('active_nights',           '[4, 5, 6]', 'ISO weekdays of the active nights: 4 = Thursday, 5 = Friday, 6 = Saturday (PRD 5.4).'),
  ('active_window_start',     '"21:00"',   'Active window start, Eastern (PRD 5.4).'),
  ('active_window_end',       '"02:00"',   'Active window end, Eastern; before the start means after midnight (PRD 5.4).'),
  ('night_boundary_hour',     '4',         'A night runs until this hour, Eastern (FR-22).'),
  ('retention_days',          '365',       'ID-linked data is deleted after this many days (FR-33).'),
  ('test_anon_ids',           '[]',        'Anonymous IDs whose rows are marked is_test (FR-38). Add your phone''s ID here.');

-- Door pins geocoded from the street addresses with OpenStreetMap (FR-28).
insert into app.bars (name, address, door_lat, door_lon, size_class, display_order) values
  ('Doggie''s Pub',  '108 S Pugh St, State College, PA 16801',    40.7950443, -77.8602538, 'medium', 1),
  ('The Phyrst',     '111 E Beaver Ave, State College, PA 16801', 40.7937487, -77.8600643, 'medium', 2),
  ('Cafe 210 West',  '210 W College Ave, State College, PA 16801', 40.7931773, -77.8630037, 'medium', 3);
