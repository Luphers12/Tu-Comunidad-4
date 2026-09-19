do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'guardian_mcp_reader') then
    create role guardian_mcp_reader
      nologin
      nosuperuser
      nocreatedb
      nocreaterole
      noinherit
      noreplication
      nobypassrls;
  end if;
end
$$;

revoke all on schema guardian_audit from guardian_mcp_reader;
grant usage on schema guardian_audit to guardian_mcp_reader;
revoke all on function guardian_audit.guardian_affiliation_integrity_v1() from guardian_mcp_reader;
grant execute on function guardian_audit.guardian_affiliation_integrity_v1() to guardian_mcp_reader;