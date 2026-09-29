-- Configure default PostgreSQL session timezone for Argentina.
-- Keep business timestamps as timestamptz; PostgreSQL stores them safely and
-- renders them using this timezone for sessions that do not override it.

alter database postgres
  set timezone to 'America/Argentina/Buenos_Aires';

create or replace function app_now_argentina()
returns timestamptz
language sql
stable
as $$
  select now();
$$;

create or replace function app_today_argentina()
returns date
language sql
stable
as $$
  select (now() at time zone 'America/Argentina/Buenos_Aires')::date;
$$;
