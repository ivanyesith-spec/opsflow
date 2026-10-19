-- OpsFlow · pruebas de las mejoras antes del piloto
-- Ejecutar DESPUES de 017. Supabase → SQL Editor → pegar todo → Run.
-- Crea usuarios y apartamentos de prueba, lo deja todo como estaba y muestra una tabla: todas las filas deben decir OK.

-- Por si una ejecución anterior se cortó a medias
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-MJ_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-MJ_');
delete from public.propiedades where codigo like 'TEST-MJ_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000f%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000f%';

create temp table resultados (n int, prueba text, resultado text);
create temp table _inicio as select coalesce((select max(id) from public.eventos), 0) as max_ev,
                                    coalesce((select max(id) from public.avisos_enviados), 0) as max_av;

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
create function pg_temp.error(q text) returns text language plpgsql as $$
begin execute q; return '(sin error)'; exception when others then return sqlerrm; end $$;
create function pg_temp.ok(n int, prueba text, cond boolean, detalle text default '') returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  insert into resultados values (n, prueba, case when coalesce(cond, false) then 'OK' else 'FALLO ' || coalesce(detalle, '') end);
end $$;
create function pg_temp.avisa(t text, i uuid) returns text language sql as $$
  select coalesce(string_agg(pf.nombre || ': ' || a.titulo, ' | ' order by pf.nombre), '(nadie)')
  from public.avisos_para(t, i) a join public.perfiles pf on pf.id = a.perfil_id
  where pf.id::text like '00000000-0000-0000-0000-0000000000f%'
$$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000f1', 'mj.cleanera@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000f2', 'mj.lidlimp@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000f3', 'mj.lidlin@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000f4', 'mj.liddrv@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000f5', 'mj.drvnorte@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000f6', 'mj.drvsur@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000f7', 'mj.operacion@opsflow.test','authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona, idioma) values
  ('00000000-0000-0000-0000-0000000000f1', 'MJ Cleaner A',  'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-0000000000f2', 'MJ LidLimp',    'Limpieza',  'lider',     null,    'es'),
  ('00000000-0000-0000-0000-0000000000f3', 'MJ LidLinens',  'Linens',    'lider',     null,    'es'),
  ('00000000-0000-0000-0000-0000000000f4', 'MJ LidDrivers', 'Drivers',   'lider',     null,    'es'),
  ('00000000-0000-0000-0000-0000000000f5', 'MJ DrvNorte',   'Drivers',   'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-0000000000f6', 'MJ DrvSur',     'Drivers',   'operador',  'Sur',   'en'),
  ('00000000-0000-0000-0000-0000000000f7', 'MJ Operacion',  'Operación', 'operacion', null,    'es');
-- MJ1 con coordenadas (Qawra), MJ2 y MJ3 sin coordenadas
insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba, lat, lng) values
  ('TEST-MJ1', 'Prueba mejoras 1', 'Norte', 'Prueba', true, 35.9530, 14.4200),
  ('TEST-MJ2', 'Prueba mejoras 2', 'Norte', 'Prueba', true, null, null),
  ('TEST-MJ3', 'Prueba mejoras 3', 'Norte', 'Prueba', true, null, null);

do $$
declare
  A  text := '00000000-0000-0000-0000-0000000000f1';
  LL text := '00000000-0000-0000-0000-0000000000f2';
  LN text := '00000000-0000-0000-0000-0000000000f3';
  LD text := '00000000-0000-0000-0000-0000000000f4';
  DN text := '00000000-0000-0000-0000-0000000000f5';
  DS text := '00000000-0000-0000-0000-0000000000f6';
  OP text := '00000000-0000-0000-0000-0000000000f7';
  F  date := current_date;
  l1 uuid; l2 uuid; l3 uuid; q1 text; q2 text; pr uuid;
  c int; e boolean; r text; j jsonb;
begin
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-MJ1 10:00\nTEST-MJ2 10:00\nTEST-MJ3 11:00', true);
  perform pg_temp.yo();
  select l.id into l1 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-MJ1';
  select l.id into l2 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-MJ2';
  select l.id into l3 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-MJ3';
  select 'OPSFLOW:' || qr_token into q1 from public.propiedades where codigo = 'TEST-MJ1';
  select 'OPSFLOW:' || qr_token into q2 from public.propiedades where codigo = 'TEST-MJ2';
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'normal');
  perform public.asignar_limpieza(l2, A::uuid, 2, 'normal');
  perform public.asignar_limpieza(l3, A::uuid, 3, 'normal');
  perform public.publicar_orden(F);

  -- 1. Los códigos QR ya no se leen de la tabla (ni líderes ni Operación); Operación los imprime con qr_lista
  perform pg_temp.como(LN);
  e := pg_temp.falla('select qr_token from public.propiedades limit 1');
  c := (select count(*) from public.propiedades where codigo like 'TEST-MJ%');
  perform pg_temp.como(LL);
  e := e and pg_temp.falla('select * from public.propiedades limit 1');
  perform pg_temp.como(OP);
  e := e and pg_temp.falla('select qr_token from public.propiedades limit 1')
         and (select count(*) = 3 from public.qr_lista() where codigo like 'TEST-MJ%');
  perform pg_temp.ok(1, 'Códigos QR ocultos en la tabla para todos; Operación los imprime con qr_lista', e and c = 3, c::text);

  -- 2. GPS al empezar: a ~22 m del apto, con precisión 15 m
  perform pg_temp.como(A);
  perform public.iniciar_con_qr(l1, q1, 35.9532, 14.4200, 15);
  perform pg_temp.yo();
  j := (select gps from public.limpiezas where id = l1);
  perform pg_temp.ok(2, 'GPS al empezar: distancia al apto y precisión guardadas',
    (j->'inicio'->>'dist')::int between 18 and 26 and (j->'inicio'->>'prec')::int = 15 and (j->'inicio'->>'sin_gps')::boolean = false, j::text);

  -- 3. Llamada antigua (sin GPS) sigue funcionando y queda "sin GPS"; apto sin coordenadas → distancia vacía
  perform pg_temp.como(A);
  perform public.iniciar_con_qr(l2, q2);
  perform public.iniciar_limpieza(l3, 35.9, 14.4, 30);
  perform pg_temp.yo();
  perform pg_temp.ok(3, 'Sin permiso de GPS: "sin GPS"; apto sin coordenadas: sin distancia',
    (select (gps->'inicio'->>'sin_gps')::boolean from public.limpiezas where id = l2)
    and (select gps->'inicio'->'dist' = 'null'::jsonb and not (gps->'inicio'->>'sin_gps')::boolean from public.limpiezas where id = l3),
    (select gps::text from public.limpiezas where id = l3));

  -- 4. GPS al cerrar a 2 km: queda registrado
  perform pg_temp.como(A);
  perform public.linens_ok(l1);
  perform public.marcar_paso(l1, p.id, true) from public.checklist_pasos p where p.tipo = 'normal' and p.obligatorio;
  perform public.registrar_foto(l1, s, l1 || '/' || s || '.jpg') from unnest(array['bedroom','bathroom','kitchen','living']) s;
  perform public.cerrar_limpieza(l1, q1, true, true, true, false, true, null, 35.9710, 14.4200, 10);
  perform pg_temp.yo();
  j := (select gps from public.limpiezas where id = l1);
  perform pg_temp.ok(4, 'GPS al cerrar: a 2 km queda registrado (sin perder el de inicio)',
    (j->'fin'->>'dist')::int between 1950 and 2050 and j ? 'inicio', j::text);

  -- 5. "No pude entrar" → el líder lo reabre → vuelve a la lista del cleaner y le avisa
  perform pg_temp.yo();
  update public.limpiezas set estado = 'asignada', inicio = null, inicio_qr = null, gps = null where id = l2;
  perform pg_temp.como(A);
  perform public.no_pude_entrar(l2, 'Guest still inside');
  e := pg_temp.falla(format('select public.reabrir_limpieza(%L)', l2));
  perform pg_temp.como(LL);
  r := pg_temp.error(format('select public.reabrir_limpieza(%L)', l1));
  perform public.reabrir_limpieza(l2);
  perform pg_temp.yo();
  r := r || ' / ' || pg_temp.avisa('limpieza', l2);
  perform pg_temp.como(A);
  c := (select count(*) from jsonb_array_elements(public.mi_dia(F)) d where d->>'id' = l2::text and d->>'estado' = 'asignada');
  perform pg_temp.ok(5, 'Reabrir: solo el líder y solo tras "no pude entrar"; vuelve al cleaner con aviso',
    e and r like 'Solo se reabre%' and r like '%MJ Cleaner A: Reopened: TEST-MJ2%' and c = 1, r);

  -- 6. Cancelar: solo líder, con motivo, no si ya empezó; desaparece del cleaner y del driver; aviso al cleaner
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.cancelar_limpieza(%L, %L)', l2, 'Reserva cancelada'));
  perform pg_temp.como(LL);
  e := e and pg_temp.falla(format('select public.cancelar_limpieza(%L, %L)', l2, ''))
         and pg_temp.falla(format('select public.cancelar_limpieza(%L, %L)', l3, 'Ya empezó'));
  perform public.cancelar_limpieza(l2, 'Reserva cancelada');
  perform pg_temp.yo();
  r := pg_temp.avisa('limpieza', l2);
  perform pg_temp.como(A);
  c := (select count(*) from jsonb_array_elements(public.mi_dia(F)) d where d->>'id' = l2::text);
  perform pg_temp.como(DN);
  c := c + (select count(*) from jsonb_array_elements(public.mi_ruta(F)->'orden') o where o->>'codigo' = 'TEST-MJ2');
  perform pg_temp.yo();
  perform pg_temp.ok(6, 'Cancelar: líder con motivo, no si ya empezó; desaparece de cleaner y driver; aviso',
    e and c = 0 and r = 'MJ Cleaner A: Cancelled: TEST-MJ2'
    and (select estado::text = 'cancelada' and cancelada_motivo = 'Reserva cancelada' from public.limpiezas where id = l2), r || ' / ' || c);

  -- 7. Driver: "no pude entregar" (solo su zona, solo si está en sus manos, con motivo) → aviso al líder de drivers
  perform pg_temp.como(A);
  perform public.linens_ok(l3);
  pr := public.reportar_pendiente(l3, 'recogida', '', 1);
  perform pg_temp.como(DS);
  e := pg_temp.falla(format('select public.no_pude_entregar(%L, %L)', pr, 'Nobody there'));
  perform pg_temp.como(DN);
  e := e and pg_temp.falla(format('select public.no_pude_entregar(%L, %L)', pr, ''));
  perform public.no_pude_entregar(pr, 'Building closed');
  j := (select t from jsonb_array_elements(public.mi_ruta(F)->'tareas') t where t->>'id' = pr::text);
  perform pg_temp.yo();
  r := pg_temp.avisa('pendiente', pr);
  perform pg_temp.ok(7, '"No pude entregar": solo su zona y con motivo; queda en la ruta marcado; avisa al líder de drivers',
    e and j->>'incidencia' = 'Building closed' and r = 'MJ LidDrivers: No se pudo entregar: TEST-MJ3', r);

  -- 8. Resolver la incidencia: solo líder de drivers u Operación
  perform pg_temp.como(DN);
  e := pg_temp.falla(format('select public.resolver_incidencia(%L)', pr));
  perform pg_temp.como(LD);
  perform public.resolver_incidencia(pr);
  perform pg_temp.yo();
  perform pg_temp.ok(8, 'Resolver incidencia: solo el líder de drivers; vuelve a la ruta normal',
    e and (select incidencia is null and estado = 'abierto' from public.pendientes where id = pr));

  -- 9. Historial: el líder ve quién hizo qué; el cleaner no
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.historial(%L)', l2));
  perform pg_temp.como(LL);
  j := public.historial(l2);
  perform pg_temp.ok(9, 'Historial de la limpieza: líder sí, cleaner no',
    e and exists (select 1 from jsonb_array_elements(j) x where x->>'que' like 'no pude entrar%' and x->>'quien' = 'MJ Cleaner A')
      and exists (select 1 from jsonb_array_elements(j) x where x->>'que' like 'cancelada%' and x->>'quien' = 'MJ LidLimp'), j::text);

  -- 10. Informe del piloto: solo Operación
  perform pg_temp.como(LL);
  e := pg_temp.falla(format('select public.informe(%L, %L)', F, F));
  perform pg_temp.como(OP);
  e := e and pg_temp.falla(format('select public.informe(%L, %L)', F, F - 1));
  j := public.informe(F, F);
  perform pg_temp.ok(10, 'Informe: solo Operación; cuenta canceladas, GPS lejos y pendientes',
    e and (j->'limpiezas'->>'canceladas')::int >= 1 and (j->'limpiezas'->>'gps_lejos')::int >= 1
      and (j->'pendientes'->'recogida'->>'total')::int >= 1, j::text);

  -- 11. Tiempos con la fecha de Malta: siguen funcionando
  perform pg_temp.como(OP);
  e := not pg_temp.falla('select * from public.tiempos_aptos()') and not pg_temp.falla('select * from public.tiempos_personas()');
  perform pg_temp.ok(11, 'Tiempos (fecha de Malta) siguen funcionando', e);

  -- 12. Ninguna funcion de OpsFlow tiene UPDATE/DELETE sin WHERE
  perform pg_temp.yo();
  select string_agg(distinct p.proname, ', ') into r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
       lateral regexp_split_to_table(regexp_replace(lower(p.prosrc), '--[^\n]*', '', 'g'), ';') st
  where n.nspname = 'public' and p.prolang in (select oid from pg_language where lanname in ('plpgsql', 'sql'))
    and st ~ '(^|\s|\()(update\s+\S+\s+set|delete\s+from)\s' and st !~ '\swhere\s';
  perform pg_temp.ok(12, 'Ningún UPDATE/DELETE sin WHERE (Supabase los bloquea)', r is null, r);
end $$;

-- Dejarlo todo como estaba
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-MJ_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-MJ_');
delete from public.propiedades where codigo like 'TEST-MJ_';
delete from public.avisos_enviados where id > (select max_av from _inicio);
delete from public.eventos where id > (select max_ev from _inicio);
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000f%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000f%';

select * from resultados order by n;
