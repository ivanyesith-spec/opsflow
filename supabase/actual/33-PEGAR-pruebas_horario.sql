-- OpsFlow · pruebas del horario estimado de cada equipo (la hora de entrada solo vale para el 1er apartamento)
-- Ejecutar DESPUES de 32-PEGAR-horario.sql. Supabase → SQL Editor → pegar todo → Run. Todas las filas deben decir OK.
-- Crea usuarios y apartamentos de prueba y lo deja todo como estaba.

delete from public.entradas_equipo where cleaner::text like '00000000-0000-0000-0000-0000000012%';
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-HO_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-HO_');
delete from public.propiedades where codigo like 'TEST-HO_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000012%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000012%';

create temp table resultados (n int, prueba text, resultado text);
create temp table _inicio as select coalesce((select max(id) from public.eventos), 0) as max_ev;

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
create function pg_temp.lim(c text) returns uuid language sql as $$
  select l.id from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
  where p.codigo = c and l.fecha = (now() at time zone 'Europe/Malta')::date $$;
-- Horario de los 3 apartamentos del equipo: "H1 11:00* · H2 12:45 · H3 14:30" (* = hora fija de entrada)
create function pg_temp.horario() returns text language sql as $$
  select string_agg(replace(p.codigo, 'TEST-', '') || ' ' || to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI')
                    || case when public._limite_fijo(l.id) then '*' else '' end, ' · ' order by l.orden)
  from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
  where p.codigo like 'TEST-HO_' and l.fecha = (now() at time zone 'Europe/Malta')::date and l.estado::text <> 'cancelada' $$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-000000001201', 'ho.cleaner@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001202', 'ho.lidlimp@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001203', 'ho.driver@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001204', 'ho.operacion@opsflow.test','authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona, idioma) values
  ('00000000-0000-0000-0000-000000001201', 'HO Cleaner',   'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000001202', 'HO LidLimp',   'Limpieza',  'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000001203', 'HO Driver',    'Drivers',   'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000001204', 'HO Operacion', 'Operación', 'operacion', null,    'es');
insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values
  ('TEST-HO1', 'Prueba horario 1', 'Norte', 'Prueba', true),
  ('TEST-HO2', 'Prueba horario 2', 'Norte', 'Prueba', true),
  ('TEST-HO3', 'Prueba horario 3', 'Norte', 'Prueba', true);

do $$
declare
  A  text := '00000000-0000-0000-0000-000000001201';
  LL text := '00000000-0000-0000-0000-000000001202';
  DR text := '00000000-0000-0000-0000-000000001203';
  OP text := '00000000-0000-0000-0000-000000001204';
  F  date := (now() at time zone 'Europe/Malta')::date;
  l1 uuid; l2 uuid; l3 uuid; r text; r2 text; j jsonb; e boolean; i int; ck uuid;
begin
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-HO1 10:00\nTEST-HO2 10:00\nTEST-HO3 13:00', true);
  perform pg_temp.yo();
  l1 := pg_temp.lim('TEST-HO1'); l2 := pg_temp.lim('TEST-HO2'); l3 := pg_temp.lim('TEST-HO3');
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'normal');
  perform public.asignar_limpieza(l2, A::uuid, 2, 'normal');
  perform public.asignar_limpieza(l3, A::uuid, 3, 'normal');
  perform public.publicar_orden(F);
  perform pg_temp.yo();

  -- 1. Solo el 1º tiene la hora de entrada; los demás: fin del anterior (90 min) + 15 min; nunca antes de su check-out
  r := pg_temp.horario();
  perform pg_temp.ok(1, '11:00 solo en el 1º; 2º = 11:00 + 90 + 15 = 12:45; 3º = 14:30 (su huésped sale a las 13:00, no cambia)',
    r = 'HO1 11:00* · HO2 12:45 · HO3 14:30', r);

  -- 2. Cambiar la hora de entrada mueve todo el día
  perform pg_temp.como(LL); perform public.fijar_entrada(F, A::uuid, '09:00'); perform pg_temp.yo();
  r := pg_temp.horario();
  perform pg_temp.ok(2, 'Entrada 09:00: el 1º empieza 10:00 (el huésped sale a las 10:00); 2º 11:45; 3º 13:30',
    r = 'HO1 10:00* · HO2 11:45 · HO3 13:30', r);

  -- 3. El tipo cuenta (refresh = 45 min) y el orden también
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'refresh');
  perform pg_temp.yo();
  r := pg_temp.horario();
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 3, 'refresh');
  perform public.asignar_limpieza(l3, A::uuid, 1, 'normal');
  perform pg_temp.yo();
  r2 := pg_temp.horario();
  perform pg_temp.ok(3, 'Refresh (45 min) acorta el día; si la líder cambia el orden, el horario se recalcula',
    r = 'HO1 10:00* · HO2 11:00 · HO3 13:00' and r2 = 'HO3 13:00* · HO2 14:45 · HO1 16:30', r || ' | ' || r2);
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'normal');
  perform public.asignar_limpieza(l3, A::uuid, 3, 'normal');
  perform pg_temp.yo();

  -- 4. Con 3+ limpiezas reales con QR de un apartamento, se usa su mediana (60 min) en vez de los 90 por defecto
  for i in 1..3 loop
    insert into public.checkouts (propiedad_id, fecha, hora_salida, es_prueba) values ((select id from public.propiedades where codigo = 'TEST-HO1'), F - i, '10:00', true)
    returning id into ck;
    -- (el checkout crea su limpieza solo; se rellena como terminada con QR: 60 min)
    update public.limpiezas set tipo = 'normal', estado = 'terminada', asignada_a = A::uuid,
           inicio = (F - i + time '10:00') at time zone 'Europe/Malta', fin = (F - i + time '11:00') at time zone 'Europe/Malta', inicio_qr = true, fin_qr = true
     where checkout_id = ck;
  end loop;
  r := pg_temp.horario();
  perform pg_temp.ok(4, 'HO1 tarda de verdad 60 min (3 limpiezas con QR): el 2º pasa a las 11:15',
    r = 'HO1 10:00* · HO2 11:15 · HO3 13:00', r);

  -- 5. Lo real manda: terminado 10:30–11:40 → el 2º a las 11:55; en curso y ya pasado de tiempo → el siguiente, ahora + 15 min
  update public.limpiezas set estado = 'terminada', inicio = (F + time '10:30') at time zone 'Europe/Malta', fin = (F + time '11:40') at time zone 'Europe/Malta' where id = l1;
  r := pg_temp.horario();
  update public.limpiezas set estado = 'en_curso', inicio = now() - interval '3 hours', fin = null where id = l1;
  r2 := to_char(public._limite_bolsa(l2) at time zone 'Europe/Malta', 'HH24:MI');
  perform pg_temp.ok(5, 'Hora real: terminado 11:40 → 2º 11:55, 3º 13:40; si sigue en curso pasado de tiempo, el 2º = ahora + 15 min',
    r = 'HO1 10:30 · HO2 11:55 · HO3 13:40'
      and r2 = to_char(greatest(now() + interval '15 minutes', (F + time '10:00') at time zone 'Europe/Malta') at time zone 'Europe/Malta', 'HH24:MI'), r || ' | ' || r2);

  -- 6. El cleaner ve a qué hora empieza cada apartamento; el driver ve si la hora de la bolsa es fija o estimada
  update public.limpiezas set estado = 'asignada', inicio = null, fin = null where id = l1;
  perform pg_temp.como(A);
  r := (select string_agg((y->>'codigo') || '=' || (y->>'inicio') || case when (y->>'inicio_fijo')::boolean then '*' else '' end, ',' order by (y->>'orden')::int)
          from jsonb_array_elements(public.mi_dia(F)) y);
  perform pg_temp.como(LL);
  j := public.horario_dia(F);
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.horario_dia(%L)', F));
  perform pg_temp.ok(6, 'Cleaner: 1º 10:00 (fijo), los demás estimados; horario_dia solo para líderes',
    r = 'TEST-HO1=10:00*,TEST-HO2=11:15,TEST-HO3=13:00' and (j -> l2::text ->> 'inicio') = '11:15'
      and not (j -> l2::text ->> 'primera')::boolean and e, coalesce(r, '-'));
end $$;

-- Dejarlo todo como estaba
delete from public.entradas_equipo where cleaner::text like '00000000-0000-0000-0000-0000000012%';
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-HO_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-HO_');
delete from public.propiedades where codigo like 'TEST-HO_';
delete from public.eventos where id > (select max_ev from _inicio);
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000012%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000012%';

select * from resultados order by n;
