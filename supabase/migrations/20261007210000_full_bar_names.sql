-- Full bar names (Max, 2026-10-07): the app shows each bar's name as stored,
-- so the two short names become the full ones.
--   Pmans    -> Primanti Bros.
--   The Gaff -> The Shandygaff
-- Same rows, ids, addresses, pins, and display_order. Data only: no table,
-- field, function, or answer-code change.

update app.bars set name = 'Primanti Bros.' where name = 'Pmans';
update app.bars set name = 'The Shandygaff' where name = 'The Gaff';

-- Stop the deploy if the live list isn't the approved one with the new names
-- (for example, if a bar was renamed in the dashboard and an update above
-- matched nothing). Test bars (is_test) are ignored.
do $$
begin
  if (select array_agg(b.name order by b.display_order) from app.bars b where b.active and not b.is_test)
     is distinct from array['Primanti Bros.', 'Doggie''s Pub', 'Brothers Bar & Grill', 'Champs Downtown',
                            'Cafe 210 West', 'The Shandygaff']
  then
    raise exception 'full bar names: the active bars are not the approved six, in order';
  end if;
end
$$;
