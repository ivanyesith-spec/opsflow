-- OpsFlow · pruebas del tráfico (TomTom)
-- Ejecutar DESPUES de 023. Supabase → SQL Editor → pegar todo → Run. Todas las filas deben decir OK.
-- Deja la tabla de tráfico como estaba (guarda una copia y la repone al final).

delete from public.propiedades where codigo like 'TEST-TR_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000008%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000008%';

create temp table resultados (n int, prueba text, resultado text);
create temp table _copia as select * from public.trafico;
create temp table _copia_estado as select * from public.trafico_estado;

create function pg_temp.como(uid text) returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.yo() returns void language plpgsql as $$
begin perform set_config('role', 'none', true); end $$;
create function pg_temp.falla(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;
create function pg_temp.ok(n int, prueba text, cond boolean, detalle text default '') returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  insert into resultados values (n, prueba, case when coalesce(cond, false) then 'OK' else 'FALLO ' || coalesce(detalle, '') end);
end $$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-000000000801', 'tr.cleaner@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000802', 'tr.driver@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000803', 'tr.lidlin@opsflow.test',  'authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona) values
  ('00000000-0000-0000-0000-000000000801', 'TR Cleaner', 'Limpieza', 'operador', 'Norte'),
  ('00000000-0000-0000-0000-000000000802', 'TR Driver',  'Drivers',  'operador', 'Norte'),
  ('00000000-0000-0000-0000-000000000803', 'TR LidLin',  'Linens',   'lider',    null);
-- Dos aptos en "Testvillé Nord" (Norte) y uno en "Testville-Sud" (Sur)
insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values
  ('TEST-TR1', 'Prueba tráfico 1', 'Norte', 'Testville Nord', true),
  ('TEST-TR2', 'Prueba tráfico 2', 'Norte', 'Testville Nord', true),
  ('TEST-TR3', 'Prueba tráfico 3', 'Sur',   'Testville-Sud',  true);

do $$
declare
  CL text := '00000000-0000-0000-0000-000000000801';
  DR text := '00000000-0000-0000-0000-000000000802';
  LN text := '00000000-0000-0000-0000-000000000803';
  e boolean; j jsonb; c int; r text;
begin
  -- 1. Solo el servidor guarda incidencias (ni drivers ni líderes)
  perform pg_temp.como(DR);
  e := pg_temp.falla($q$select public.trafico_guardar('[]'::jsonb)$q$) and pg_temp.falla('select * from public.trafico')
       and pg_temp.falla('select public.trafico_toca()');
  perform pg_temp.ok(1, 'Solo el servidor guarda; nadie lee la tabla directamente', e);

  -- 2. Guardar: cada incidencia va a la zona de los aptos de ese pueblo (aunque se escriba distinto); si no, General
  perform pg_temp.yo();
  c := public.trafico_guardar($j$[
    {"id":"t1","tipo":1,"gravedad":3,"municipio":"Testville Nord","desde":"Triq A","hasta_calle":"Triq B","retraso_min":12,"km":1.5,"detalle":"Accident","fin":"2026-10-10T12:00:00Z","lat":35.95,"lng":14.42},
    {"id":"t2","tipo":8,"gravedad":4,"municipio":"testville sud","retraso_min":0},
    {"id":"t3","tipo":9,"gravedad":3,"municipio":"Aeroport Inventado","retraso_min":5}]$j$);
  select string_agg(id || ':' || zona, ' ' order by id) into r from public.trafico where id in ('t1', 't2', 't3');
  perform pg_temp.ok(2, 'Zona según tus aptos del pueblo (Norte / Sur); pueblo sin aptos → General', c = 3 and r = 't1:Norte t2:Sur t3:General', r);

  -- 3. Una nueva consulta reemplaza la anterior (lo que ya no está, desaparece)
  c := public.trafico_guardar($j$[{"id":"t2","tipo":8,"gravedad":4,"municipio":"Testville-Sud"}]$j$);
  perform pg_temp.ok(3, 'Cada consulta reemplaza la anterior', c = 1 and (select count(*) from public.trafico) = 1);

  -- 4. Lo ven drivers y líderes; el cleaner no
  perform pg_temp.como(DR);
  j := public.trafico_actual();
  perform pg_temp.como(LN);
  c := jsonb_array_length(public.trafico_actual()->'incidencias');
  perform pg_temp.como(CL);
  e := pg_temp.falla('select public.trafico_actual()');
  perform pg_temp.ok(4, 'Lo ven drivers y líderes (con la hora de la consulta); el cleaner no',
    e and c = 1 and j->'incidencias'->0->>'zona' = 'Sur' and j->>'actualizado_en' is not null, j::text);

  -- 5. Protección del cupo: tras una consulta, no toca otra hasta 5 min después
  perform pg_temp.yo();
  e := public.trafico_toca();
  update public.trafico_estado set actualizado_en = now() - interval '6 minutes' where id = 1;
  perform pg_temp.ok(5, 'No vuelve a consultar TomTom antes de 5 minutos', e = false and public.trafico_toca());

  -- 6. Si TomTom falla, se guarda el error y se mantienen las incidencias anteriores
  perform public.trafico_guardar(null, 'TomTom 403');
  perform pg_temp.como(DR);
  j := public.trafico_actual();
  perform pg_temp.ok(6, 'Si TomTom falla: se ve el error y lo anterior sigue', j->>'error' = 'TomTom 403' and jsonb_array_length(j->'incidencias') = 1, j::text);
end $$;

-- Dejarlo todo como estaba
delete from public.trafico where true;
insert into public.trafico select * from _copia;
update public.trafico_estado t set actualizado_en = c.actualizado_en, error = c.error from _copia_estado c where t.id = c.id;
delete from public.propiedades where codigo like 'TEST-TR_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000008%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000008%';

select * from resultados order by n;
