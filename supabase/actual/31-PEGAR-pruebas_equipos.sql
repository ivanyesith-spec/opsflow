-- OpsFlow · pruebas de equipos: varias personas en el mismo apartamento, una sala = una persona
-- Ejecutar DESPUES de 30-PEGAR-equipos.sql. Supabase → SQL Editor → pegar todo → Run. Todas las filas deben decir OK.
-- Crea usuarios y apartamentos de prueba y lo deja todo como estaba.

-- Por si una ejecución anterior se cortó a medias
delete from public.equipo_miembros where perfil_id::text like '00000000-0000-0000-0000-0000000011%';
delete from public.equipos where responsable::text like '00000000-0000-0000-0000-0000000011%';
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-EQ_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-EQ_');
delete from public.propiedades where codigo like 'TEST-EQ_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000011%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000011%';

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
create function pg_temp.lim(c text) returns uuid language sql as $$
  select l.id from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
  where p.codigo = c and l.fecha = (now() at time zone 'Europe/Malta')::date $$;
-- Pasos de una sala (de una limpieza normal)
create function pg_temp.pasos(s text) returns setof int language sql as $$
  select id from public.checklist_pasos where tipo = 'normal' and activo and sala = s order by orden $$;
create function pg_temp.paso(s text) returns int language sql as $$ select min(x) from pg_temp.pasos(s) x $$;
create function pg_temp.duen(l uuid, s text) returns text language sql as $$
  select coalesce((select split_part(p.nombre, ' ', 2) from public.limpieza_salas x join public.perfiles p on p.id = x.perfil_id
                   where x.limpieza_id = l and x.sala = s), 'libre') $$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-000000001101', 'eq.ana@opsflow.test',     'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001102', 'eq.beto@opsflow.test',    'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001103', 'eq.carla@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001104', 'eq.dani@opsflow.test',    'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001105', 'eq.lidlimp@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001106', 'eq.driver@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001107', 'eq.operacion@opsflow.test','authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona, idioma) values
  ('00000000-0000-0000-0000-000000001101', 'EQ Ana',       'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000001102', 'EQ Beto',      'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000001103', 'EQ Carla',     'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000001104', 'EQ Dani',      'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000001105', 'EQ LidLimp',   'Limpieza',  'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000001106', 'EQ Driver',    'Drivers',   'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000001107', 'EQ Operacion', 'Operación', 'operacion', null,    'es');
insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values
  ('TEST-EQ1', 'Prueba equipo 1', 'Norte', 'Prueba', true),
  ('TEST-EQ2', 'Prueba equipo 2', 'Norte', 'Prueba', true),
  ('TEST-EQ3', 'Prueba equipo 3', 'Norte', 'Prueba', true);

do $$
declare
  A  text := '00000000-0000-0000-0000-000000001101';
  B  text := '00000000-0000-0000-0000-000000001102';
  CA text := '00000000-0000-0000-0000-000000001103';
  Dd text := '00000000-0000-0000-0000-000000001104';
  LL text := '00000000-0000-0000-0000-000000001105';
  DR text := '00000000-0000-0000-0000-000000001106';
  OP text := '00000000-0000-0000-0000-000000001108';
  F  date := (now() at time zone 'Europe/Malta')::date;
  l1 uuid; l2 uuid; l3 uuid; eq uuid; eq2 uuid; q1 text; q3 text; c int; e boolean; r text; j jsonb;
begin
  OP := '00000000-0000-0000-0000-000000001107';
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-EQ1 10:00\nTEST-EQ2 10:00\nTEST-EQ3 10:00', true);
  perform pg_temp.yo();
  l1 := pg_temp.lim('TEST-EQ1'); l2 := pg_temp.lim('TEST-EQ2'); l3 := pg_temp.lim('TEST-EQ3');
  select 'OPSFLOW:' || qr_token into q1 from public.propiedades where codigo = 'TEST-EQ1';
  select 'OPSFLOW:' || qr_token into q3 from public.propiedades where codigo = 'TEST-EQ3';

  -- 1. Formar equipos: solo la líder; 2–3 cleaners activos
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.guardar_equipo(array[%L, %L]::uuid[])', A, B));
  perform pg_temp.como(LL);
  e := e and pg_temp.falla(format('select public.guardar_equipo(array[%L]::uuid[])', A))
         and pg_temp.falla(format('select public.guardar_equipo(array[%L, %L]::uuid[])', A, DR))
         and pg_temp.falla(format('select public.guardar_equipo(array[%L, %L, %L, %L]::uuid[])', A, B, CA, Dd));
  eq := public.guardar_equipo(array[A, B]::uuid[]);
  r := (select y->>'nombre' from jsonb_array_elements(public.equipos_activos()) y where y->>'id' = eq::text);
  perform pg_temp.ok(1, 'Equipos: solo la líder, de 2 o 3 cleaners; "EQ Ana + EQ Beto"', e and r = 'EQ Ana + EQ Beto', coalesce(r, '-'));

  -- 2. Asignar a un miembro = asignar al equipo (responsable + foto fija); los dos lo ven, alguien de fuera no
  perform public.asignar_limpieza(l1, B::uuid, 1, 'normal');
  perform public.asignar_limpieza(l2, A::uuid, 2, 'normal');
  perform public.asignar_limpieza(l3, Dd::uuid, 1, 'normal');
  perform public.publicar_orden(F);
  perform pg_temp.yo();
  r := (select asignada_a::text from public.limpiezas where id = l1);
  c := (select count(*) from public.limpieza_miembros where limpieza_id = l1);
  perform pg_temp.como(B);
  j := (select y from jsonb_array_elements(public.mi_dia(F)) y where y->>'id' = l1::text);
  e := (select count(*) = 2 from public.limpiezas where id in (l1, l2));
  perform pg_temp.como(CA);
  e := e and (select count(*) = 0 from public.limpiezas where id in (l1, l2)) and jsonb_array_length(public.mi_dia(F)) = 0
         and pg_temp.falla(format('select public.mi_checklist(%L)', l1));
  perform pg_temp.ok(2, 'Asignar a Beto = al equipo: responsable Ana, los 2 lo ven ("con Ana"); Carla no',
    r = A and c = 2 and j->>'con' = 'EQ' and e, r || ' ' || c || ' ' || coalesce(j::text, '-'));

  -- 3. El orden publicado avisa a cada miembro
  perform pg_temp.yo();
  r := (select string_agg(a.perfil_id::text, ',' order by a.perfil_id) from public.avisos_para('orden', null, F) a where a.perfil_id::text like '00000000-0000-0000-0000-0000000011%');
  perform pg_temp.ok(3, 'Orden publicado: aviso a Ana, a Beto y a Dani', r = A || ',' || B || ',' || Dd, r);

  -- 4. Ana empieza (queda "llegada"); Beto no marca nada hasta llegar; llega con el QR
  perform pg_temp.como(A);
  perform public.iniciar_con_qr(l1, q1);
  perform public.linens_ok(l1);
  perform pg_temp.como(B);
  r := pg_temp.error(format('select public.marcar_paso(%L, %s, true)', l1, pg_temp.paso('bathroom')));
  e := pg_temp.falla(format('select public.llegar_limpieza(%L, %L)', l1, q3));     -- QR de otro apto
  perform public.llegar_limpieza(l1, q1);
  perform pg_temp.yo();
  c := (select count(*) from public.limpieza_personas where limpieza_id = l1);
  perform pg_temp.ok(4, 'Ana empieza y queda llegada; Beto no marca hasta llegar; llega con su QR (no con el de otro apto); 2 personas',
    r like 'Scan the QR when you arrive%' and e and c = 2 and (select personas from public.limpiezas where id = l1) = 2, r || ' ' || c);

  -- 5. Una sala = una persona: la toma quien marca primero
  perform pg_temp.como(A);
  perform public.marcar_paso(l1, pg_temp.paso('kitchen'), true);
  perform pg_temp.como(B);
  r := pg_temp.error(format('select public.marcar_paso(%L, %s, true)', l1, pg_temp.paso('kitchen')));
  perform public.marcar_paso(l1, pg_temp.paso('bathroom'), true);
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.marcar_paso(%L, %s, false)', l1, pg_temp.paso('bathroom')));   -- tampoco desmarcar lo del otro
  perform pg_temp.ok(5, 'Cocina de Ana: Beto no la marca ("Ana already has the kitchen"); baño de Beto: Ana no lo toca',
    r = 'EQ already has the kitchen.' or r like '% already has the kitchen.', r) ;
  perform pg_temp.ok(6, 'Dueños: cocina Ana, baño Beto; Ana tampoco desmarca el baño',
    pg_temp.duen(l1, 'kitchen') = 'Ana' and pg_temp.duen(l1, 'bathroom') = 'Beto' and e, pg_temp.duen(l1, 'kitchen') || '/' || pg_temp.duen(l1, 'bathroom'));

  -- 7. La sección "final" es común; las fotos de sala solo las hace su dueño; la de la basura, cualquiera
  perform pg_temp.como(A); perform public.marcar_paso(l1, min(x), true) from pg_temp.pasos('final') x;
  perform pg_temp.como(B); perform public.marcar_paso(l1, max(x), true) from pg_temp.pasos('final') x;
  e := pg_temp.falla(format('select public.registrar_foto(%L, %L, %L)', l1, 'kitchen', l1 || '/kitchen.jpg'));
  perform public.registrar_foto(l1, 'bathroom', l1 || '/bathroom.jpg');
  perform public.registrar_foto(l1, 'basura', l1 || '/basura.jpg');
  perform pg_temp.yo();
  c := (select count(*) from public.limpieza_salas where limpieza_id = l1);
  perform pg_temp.ok(7, '"final" la marcan los dos sin dueño; Beto no hace la foto de la cocina; sí la del baño y la basura',
    e and c = 2 and (select count(*) from public.fotos_cierre where limpieza_id = l1 and sala in ('bathroom', 'basura')) = 2, c::text);

  -- 8. Soltar: el dueño suelta su sala; nadie suelta la de otro; la líder sí
  perform pg_temp.como(B);
  e := pg_temp.falla(format('select public.soltar_sala(%L, %L)', l1, 'kitchen'));
  perform public.soltar_sala(l1, 'bathroom');
  r := pg_temp.duen(l1, 'bathroom');
  perform pg_temp.como(A); perform public.marcar_paso(l1, pg_temp.paso('bathroom'), false);   -- ahora Ana lo toma
  perform pg_temp.como(LL); perform public.soltar_sala(l1, 'bathroom');
  perform pg_temp.ok(8, 'Beto no suelta la cocina de Ana; suelta su baño (libre); Ana lo toma; la líder lo suelta',
    e and r = 'libre' and pg_temp.duen(l1, 'bathroom') = 'libre', r);

  -- 9. Sala terminada (todos sus pasos): queda con hora; su dueño ya no la suelta (la líder sí)
  perform pg_temp.como(A);
  perform public.marcar_paso(l1, x, true) from pg_temp.pasos('kitchen') x;
  r := pg_temp.error(format('select public.soltar_sala(%L, %L)', l1, 'kitchen'));
  perform pg_temp.yo();
  perform pg_temp.ok(9, 'Cocina completa: terminada; Ana ya no la suelta', r like 'That room is finished%'
    and (select terminada_en is not null from public.limpieza_salas where limpieza_id = l1 and sala = 'kitchen'), r);

  -- 10. Cerrar: cualquier miembro, cuando todo está completo
  perform pg_temp.como(B);
  perform public.marcar_paso(l1, x, true) from pg_temp.pasos('bathroom') x;
  perform pg_temp.como(A);
  perform public.marcar_paso(l1, x, true) from pg_temp.pasos('bedroom') x;
  perform public.marcar_paso(l1, x, true) from pg_temp.pasos('living') x;
  perform public.marcar_paso(l1, x, true) from pg_temp.pasos('final') x;
  perform public.registrar_foto(l1, s, l1 || '/' || s || '.jpg') from unnest(array['kitchen', 'bedroom', 'living']) s;
  perform pg_temp.como(B);
  e := pg_temp.falla(format('select public.registrar_foto(%L, %L, %L)', l1, 'living', l1 || '/living2.jpg'));
  perform public.cerrar_limpieza(l1, q1, true, true, true, false, true);
  perform pg_temp.yo();
  r := (select string_agg(sala || '=' || pg_temp.duen(l1, sala), ',' order by sala) from public.limpieza_salas where limpieza_id = l1);
  perform pg_temp.ok(10, 'Beto cierra con todo completo; salas: cocina/dorm./salón Ana, baño Beto',
    e and (select estado::text from public.limpiezas where id = l1) = 'terminada'
      and r = 'bathroom=Beto,bedroom=Ana,kitchen=Ana,living=Ana', r);

  -- 11. Seguimiento y tiempos por sala (líder)
  update public.limpieza_salas set desde = desde - interval '20 minutes' where limpieza_id = l1;
  perform pg_temp.como(LL);
  j := public.salas_dia(F) -> l1::text;
  c := (select count(*) from public.tiempos_salas(30) t where t.codigo = 'TEST-EQ1');
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.salas_dia(%L)', F)) and pg_temp.falla('select * from public.tiempos_salas(30)');
  perform pg_temp.ok(11, 'Seguimiento: equipo, 2 llegadas y 4 salas; tiempos por sala; un cleaner no lo ve',
    j->>'equipo' = 'EQ Ana + EQ Beto' and jsonb_array_length(j->'llegadas') = 2 and jsonb_array_length(j->'salas') = 4 and c = 4 and e, coalesce(j::text, '-') || ' c=' || c);

  -- 12. Cambiar el equipo: Beto pasa con Carla. Lo que no ha empezado cambia; lo terminado no
  perform pg_temp.como(LL);
  eq2 := public.guardar_equipo(array[B, CA]::uuid[]);
  perform pg_temp.yo();
  r := (select string_agg(split_part(p.nombre, ' ', 2), ',' order by p.nombre) from public.limpieza_miembros m join public.perfiles p on p.id = m.perfil_id where m.limpieza_id = l2);
  e := not (select activo from public.equipos where id = eq);    -- el equipo viejo se queda con 1: se deshace
  perform pg_temp.como(B);
  c := (select count(*) from public.limpiezas where id in (l1, l2));
  perform pg_temp.ok(12, 'Beto + Carla: el equipo viejo se deshace; la limpieza sin empezar queda solo para Ana; Beto sigue viendo la terminada',
    e and r = 'Ana' and c = 1 and (select count(*) from public.limpiezas where id = l1) = 1, coalesce(r, '-') || ' c=' || c);

  -- 13. Cleaner sin equipo: igual que antes (empieza, marca sin "llegar"); limpieza antigua sin llegadas: vale su cleaner
  perform pg_temp.como(Dd);
  perform public.iniciar_con_qr(l3, q3);
  perform public.linens_ok(l3);
  perform public.marcar_paso(l3, pg_temp.paso('kitchen'), true);
  perform pg_temp.yo();
  delete from public.limpieza_personas where limpieza_id = l3;
  perform pg_temp.como(Dd);
  perform public.marcar_paso(l3, pg_temp.paso('living'), true);
  perform pg_temp.yo();
  perform pg_temp.ok(13, 'Cleaner solo: todo como antes (también una limpieza antigua sin llegadas)',
    pg_temp.duen(l3, 'kitchen') = 'Dani' and pg_temp.duen(l3, 'living') = 'Dani', pg_temp.duen(l3, 'living'));

  -- 14. Drivers ven el nombre del equipo; deshacer equipo
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l2, CA::uuid, 3, 'normal');        -- al equipo Beto + Carla
  perform pg_temp.como(DR);
  r := (select y->>'cleaner' from jsonb_array_elements(public.mi_ruta(F)->'orden') y where y->>'codigo' = 'TEST-EQ2');
  perform pg_temp.como(LL);
  perform public.deshacer_equipo(eq2);
  perform pg_temp.yo();
  c := (select count(*) from public.limpieza_miembros where limpieza_id = l2);
  perform pg_temp.ok(14, 'Driver ve "EQ Beto + EQ Carla"; al deshacer, la limpieza sin empezar queda para el responsable',
    r = 'EQ Beto + EQ Carla' and c = 1 and not (select activo from public.equipos where id = eq2), coalesce(r, '-') || ' ' || c);
end $$;

-- Dejarlo todo como estaba
delete from public.equipo_miembros where perfil_id::text like '00000000-0000-0000-0000-0000000011%';
delete from public.equipos where responsable::text like '00000000-0000-0000-0000-0000000011%';
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-EQ_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-EQ_');
delete from public.propiedades where codigo like 'TEST-EQ_';
delete from public.avisos_enviados where id > (select max_av from _inicio);
delete from public.eventos where id > (select max_ev from _inicio);
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000011%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000011%';

select * from resultados order by n;
