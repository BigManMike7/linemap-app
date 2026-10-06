-- The bar list for the first release (PRD 7.3, FR-28, FR-37). Approved by Max
-- on 2026-10-06.
--
-- Active bars after this migration, in display_order:
--   1 Pmans                 130 Heister St                  (new)
--   2 Doggie's Pub          108 S Pugh St                   (existing row)
--   3 Brothers Bar & Grill  134 S Allen St                  (new)
--   4 Champs Downtown       139 S Allen St                  (new)
--   5 Cafe 210 West         210 W College Ave               (existing row)
--   6 The Gaff              212 E College Ave (rear)        (new)
-- All in State College, PA 16801.
--
-- - Door pins for the new bars are OpenStreetMap (Nominatim) geocodes of these
--   addresses, the same source as the starting pins (FR-28). New bars are
--   size_class 'medium' and real rows (is_test false).
-- - Doggie's Pub and Cafe 210 West keep their rows: same id, address, and
--   coordinates. Only their display_order changes.
-- - The Phyrst is retired the admin way (FR-37): active = false, never
--   deleted, so its id is never reused and any history keeps its bar. Its
--   display_order moves to 7, after the active bars, so no two bars share an
--   order (if it is ever reactivated it shows last).
-- - No table, field, function, or answer-code change; data only.

update app.bars set display_order = 2 where name = 'Doggie''s Pub';
update app.bars set display_order = 5 where name = 'Cafe 210 West';
update app.bars set active = false, display_order = 7 where name = 'The Phyrst';

insert into app.bars (name, address, door_lat, door_lon, size_class, display_order, is_test) values
  ('Pmans',                '130 Heister St, State College, PA 16801',           40.7966833, -77.8569426, 'medium', 1, false),
  ('Brothers Bar & Grill', '134 S Allen St, State College, PA 16801',           40.7936366, -77.8607833, 'medium', 3, false),
  ('Champs Downtown',      '139 S Allen St, State College, PA 16801',           40.7937545, -77.8605492, 'medium', 4, false),
  ('The Gaff',             '212 E College Ave (rear), State College, PA 16801', 40.7953248, -77.8595640, 'medium', 6, false);

-- Stop the deploy if the live list isn't exactly the approved one (for
-- example, if a starting bar was renamed in the dashboard and an update above
-- matched nothing). Test bars (is_test) are ignored.
do $$
begin
  if (select array_agg(b.name order by b.display_order) from app.bars b where b.active and not b.is_test)
     is distinct from array['Pmans', 'Doggie''s Pub', 'Brothers Bar & Grill', 'Champs Downtown',
                            'Cafe 210 West', 'The Gaff']
  then
    raise exception 'bar list: the active bars are not the approved six, in order';
  end if;
  if not exists (select 1 from app.bars b where b.name = 'The Phyrst' and not b.active) then
    raise exception 'bar list: The Phyrst should be kept, inactive';
  end if;
end
$$;
