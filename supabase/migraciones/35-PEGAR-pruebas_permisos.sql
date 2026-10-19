-- OpsFlow · pruebas de 34: asignación solo por el líder de cada departamento + sustituciones temporales
-- Ejecutar DESPUÉS de 34-PEGAR-permisos_sustituciones.sql, en el proyecto de PRUEBAS.
-- Supabase → SQL Editor → pegar todo → Run. Todas las filas deben decir OK.
-- Crea usuarios y un apartamento de prueba y lo deja todo como estaba.

begin;

-- Freno de seguridad: con propiedades REALES esto parece PRODUCCIÓN → parar sin tocar nada
do $$
begin
  if exists (select 1 from public.propiedades where not es_prueba) then
    raise exception 'PARADO: hay propiedades reales en esta base de datos (¿es producción?). No se ha cambiado nada.';
  end if;
  if to_regclass('public.sustituciones') is null then
    raise exception 'Falta la migración 34: pega primero 34-PEGAR-permisos_sustituciones.sql.';
  end if;
end $$;

-- Por si una ejecución anterior se cortó a medias
delete from public.sustituciones where sustituto::text like '00000000-0000-0000-0000-0000000034%' or nombrado_por::text like '00000000-0000-0000-0000-0000000034%';
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-PM_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-PM_');
delete from public.propiedades where codigo like 'TEST-PM_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000034%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000034%';

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
create function pg_temp.ok(n int, prueba text, cond boolean, detalle text default '') returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  insert into resultados values (n, prueba, case when coalesce(cond, false) then 'OK' else 'FALLO ' || coalesce(detalle, '') end);
end $$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-000000003401', 'pm.lidlimp@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000003402', 'pm.ana@opsflow.test',       'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000003403', 'pm.beto@opsflow.test',      'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000003404', 'pm.liddrv@opsflow.test',    'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000003405', 'pm.driver@opsflow.test',    'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000003406', 'pm.operacion@opsflow.test', 'authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona, idioma) values
  ('00000000-0000-0000-0000-000000003401', 'PM LidLimp',   'Limpieza',  'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000003402', 'PM Ana',       'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000003403', 'PM Beto',      'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000003404', 'PM LidDrv',    'Drivers',   'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000003405', 'PM Driver',    'Drivers',   'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000003406', 'PM Operacion', 'Operación', 'operacion', null,    'es');
insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values ('TEST-PM1', 'Prueba permisos 1', 'Norte', 'Prueba', true);

do $$
declare
  LL text := '00000000-0000-0000-0000-000000003401';
  CA text := '00000000-0000-0000-0000-000000003402';
  CB text := '00000000-0000-0000-0000-000000003403';
  LD text := '00000000-0000-0000-0000-000000003404';
  DR text := '00000000-0000-0000-0000-000000003405';
  OP text := '00000000-0000-0000-0000-000000003406';
  F  date := (now() at time zone 'Europe/Malta')::date;
  l1 uuid; pe uuid; s1 uuid; s2 uuid; n int; e boolean; e2 boolean; e3 boolean; e4 boolean; x text; j jsonb;
begin
  -- Operación sigue cargando checkouts (no es asignar personal)
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, 'TEST-PM1 10:00', true);
  perform pg_temp.yo();
  select l.id into l1 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where p.codigo = 'TEST-PM1' and l.fecha = F;

  -- 1. Operación ya no asigna cleaners
  perform pg_temp.como(OP);
  e := pg_temp.falla(format('select public.asignar_limpieza(%L, %L, 1, %L)', l1, CA, 'normal'));
  perform pg_temp.ok(1, 'Operación NO puede asignar una limpieza', e);

  -- 2. Ni publicar, formar equipos, deshacer o fijar la hora de entrada
  perform pg_temp.como(OP);
  e  := pg_temp.falla(format('select public.publicar_orden(%L)', F));
  e2 := pg_temp.falla(format('select public.guardar_equipo(array[%L, %L]::uuid[])', CA, CB));
  e3 := pg_temp.falla(format('select public.fijar_entrada(%L, %L, %L)', F, CA, '11:00'));
  e4 := pg_temp.falla(format('select public.deshacer_equipo(%L)', gen_random_uuid()));
  perform pg_temp.ok(2, 'Operación NO publica, NO forma/deshace equipos, NO fija la entrada', e and e2 and e3 and e4,
    e::text || e2::text || e3::text || e4::text);

  -- 3. El líder de limpieza sí asigna y publica
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, CA::uuid, 1, 'normal');
  n := public.publicar_orden(F);
  perform pg_temp.yo();
  perform pg_temp.ok(3, 'Líder de limpieza asigna y publica',
    (select asignada_a::text = CA and publicada from public.limpiezas where id = l1), n::text);

  -- 4. Otro líder (Drivers) no asigna limpiezas
  perform pg_temp.como(LD);
  e := pg_temp.falla(format('select public.asignar_limpieza(%L, %L, 1, %L)', l1, CB, 'normal'));
  perform pg_temp.ok(4, 'Líder de drivers NO asigna limpiezas', e);

  -- 5. Drivers: Operación y el líder de limpieza NO asignan; el líder de drivers sí
  perform pg_temp.yo();
  insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, creado_por, es_prueba)
  select l1, propiedad_id, zona, fecha, 'recogida', 'Basura', 1, CA::uuid, true from public.limpiezas where id = l1
  returning id into pe;
  perform pg_temp.como(OP);
  e := pg_temp.falla(format('select public.asignar_tarea(%L, %L)', pe, DR));
  perform pg_temp.como(LL);
  e2 := pg_temp.falla(format('select public.asignar_tarea(%L, %L)', pe, DR));
  perform pg_temp.ok(5, 'Operación y líder de limpieza NO asignan drivers', e and e2, e::text || e2::text);
  perform pg_temp.como(LD);
  perform public.asignar_tarea(pe, DR::uuid);
  perform pg_temp.yo();
  perform pg_temp.ok(6, 'Líder de drivers asigna la tarea', (select tomado_por::text = DR from public.pendientes where id = pe));

  -- 7. Solo Operación nombra sustitutos
  perform pg_temp.como(LL);
  e := pg_temp.falla(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Limpieza', CB, '1 hour', 'Prueba'));
  perform pg_temp.como(CB);
  e2 := pg_temp.falla(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Limpieza', CB, '1 hour', 'Prueba'));
  perform pg_temp.ok(7, 'Líder y operador NO pueden nombrar sustitutos', e and e2, e::text || e2::text);

  -- 8. El sustituto tiene que ser un operador activo del MISMO departamento
  perform pg_temp.como(OP);
  e  := pg_temp.falla(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Limpieza', DR, '1 hour', 'Prueba'));
  e2 := pg_temp.falla(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Limpieza', LL, '1 hour', 'Prueba'));
  e3 := pg_temp.falla(format('select public.nombrar_sustituto(%L, %L, now() + interval %L, now(), %L)', 'Limpieza', CB, '1 hour', 'Prueba'));
  perform pg_temp.ok(8, 'Rechaza: driver para limpieza, un líder, fechas al revés', e and e2 and e3, e::text || e2::text || e3::text);

  -- 9. Sustituto vigente: actúa como líder de SU departamento
  perform pg_temp.como(OP);
  s1 := public.nombrar_sustituto('Limpieza', CB::uuid, now() - interval '1 minute', now() + interval '1 hour', 'Vacaciones de la líder');
  perform pg_temp.como(CB);
  x := public.mi_nivel()::text;
  j := public.mi_sustitucion();
  perform public.asignar_limpieza(l1, CB::uuid, 1, 'normal');
  n := (select count(*) from public.perfiles where departamento = 'Limpieza' and id::text like '00000000-0000-0000-0000-0000000034%');
  perform pg_temp.yo();
  perform pg_temp.ok(9, 'Sustituto vigente: nivel lider, puede asignar y ve a su departamento',
    x = 'lider' and j->>'departamento' = 'Limpieza' and n = 3
    and (select asignada_a::text = CB from public.limpiezas where id = l1), x || ' ' || n);

  -- 10. ...pero no actúa sobre otro departamento
  perform pg_temp.como(CB);
  e := pg_temp.falla(format('select public.asignar_tarea(%L, %L)', pe, DR));
  perform pg_temp.ok(10, 'Sustituto de limpieza NO asigna drivers', e);

  -- 11. Un solo sustituto por departamento en las mismas fechas (también evita el doble toque)
  perform pg_temp.como(OP);
  e := pg_temp.falla(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Limpieza', CA, '2 hours', 'Prueba'));
  perform pg_temp.ok(11, 'No se solapan dos sustitutos del mismo departamento', e);

  -- 12. Sustitución programada (futura): todavía no da nivel de líder
  perform pg_temp.como(OP);
  s2 := public.nombrar_sustituto('Drivers', DR::uuid, now() + interval '1 day', now() + interval '2 days', 'Permiso del líder');
  perform pg_temp.como(DR);
  x := public.mi_nivel()::text;
  e := pg_temp.falla(format('select public.asignar_tarea(%L, %L)', pe, DR));
  perform pg_temp.ok(12, 'Sustitución programada: sigue siendo operador hasta la fecha', x = 'operador' and e and public.mi_sustitucion() is null, x);

  -- 13. Revocar: deja de ser líder al momento
  perform pg_temp.como(OP);
  perform public.revocar_sustitucion(s1);
  perform pg_temp.como(CB);
  x := public.mi_nivel()::text;
  e := pg_temp.falla(format('select public.asignar_limpieza(%L, %L, 1, %L)', l1, CA, 'normal'));
  perform pg_temp.ok(13, 'Revocada: vuelve a operador y ya no asigna', x = 'operador' and e, x);

  -- 14. Lista solo para Operación, con su estado
  perform pg_temp.como(OP);
  j := public.sustituciones_lista();
  perform pg_temp.como(LL);
  e := pg_temp.falla('select public.sustituciones_lista()');
  perform pg_temp.ok(14, 'Lista: Operación ve revocada y programada; el líder no puede leerla',
    e and j @> jsonb_build_array(jsonb_build_object('id', s1, 'estado', 'revocada'))
      and j @> jsonb_build_array(jsonb_build_object('id', s2, 'estado', 'programada')), left(j::text, 120));

  -- 15. Nadie lee ni escribe la tabla directamente desde la app
  perform pg_temp.como(OP);
  e  := pg_temp.falla('select count(*) from public.sustituciones');
  e2 := pg_temp.falla(format('update public.sustituciones set hasta = now() + interval %L where id = %L', '9 days', s2));
  perform pg_temp.ok(15, 'Tabla sustituciones cerrada al navegador (solo funciones)', e and e2, e::text || e2::text);

  -- 16. Queda registrado quién nombró y quién revocó
  perform pg_temp.yo();
  perform pg_temp.ok(16, 'Eventos de nombrar y revocar',
    exists (select 1 from public.eventos where id > (select max_ev from _inicio) and quien::text = OP and que like 'sustituto de Limpieza: PM Beto%')
    and exists (select 1 from public.eventos where id > (select max_ev from _inicio) and quien::text = OP and que like 'sustitución revocada: Limpieza%')
    and (select revocada_por::text = OP from public.sustituciones where id = s1));

  -- 17. Operación sigue viendo el seguimiento (lectura no cambia)
  perform pg_temp.como(OP);
  n := (select count(*) from public.limpiezas where id = l1);
  perform pg_temp.ok(17, 'Operación sigue leyendo limpiezas (Seguimiento)', n = 1, n::text);
end $$;

-- Dejarlo todo como estaba
delete from public.sustituciones where sustituto::text like '00000000-0000-0000-0000-0000000034%' or nombrado_por::text like '00000000-0000-0000-0000-0000000034%';
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-PM_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-PM_');
delete from public.propiedades where codigo like 'TEST-PM_';
delete from public.avisos_enviados where id > (select max_av from _inicio);
delete from public.eventos where id > (select max_ev from _inicio);
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000034%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000034%';

commit;

select * from resultados order by n;
