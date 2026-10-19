-- OpsFlow · pruebas del modulo limpieza-guiada
-- Ejecutar DESPUES de 010. Supabase → SQL Editor → pegar todo → Run.
-- Crea usuarios y limpiezas de prueba, lo deja todo como estaba y muestra una tabla: todas las filas deben decir OK.

-- Por si una ejecución anterior se cortó a medias
select set_config('storage.allow_delete_query', 'true', false);  -- Supabase solo deja borrar fotos así si se pide expresamente
delete from storage.objects where bucket_id = 'fotos-cierre' and split_part(name, '/', 1) in
  (select l.id::text from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where p.codigo like 'TEST-LG_');
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-LG_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-LG_');
delete from public.propiedades where codigo like 'TEST-LG_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000b%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000b%';

create temp table resultados (n int, prueba text, resultado text);
create temp table _inicio as select coalesce(max(id), 0) as max_id from public.eventos;

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

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000b1', 'lg.cleanera@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', 'lg.cleanerb@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b3', 'lg.lidlimp@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b4', 'lg.lidlin@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b5', 'lg.operacion@opsflow.test','authenticated', 'authenticated');
insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values
  ('TEST-LG1', 'Prueba limpieza guiada 1', 'Norte', 'Prueba', true),
  ('TEST-LG2', 'Prueba limpieza guiada 2', 'Norte', 'Prueba', true),
  ('TEST-LG3', 'Prueba limpieza guiada 3', 'Norte', 'Prueba', true);
insert into public.perfiles (id, nombre, departamento, nivel, zona) values
  ('00000000-0000-0000-0000-0000000000b1', 'LG Cleaner A', 'Limpieza',  'operador',  'Norte'),
  ('00000000-0000-0000-0000-0000000000b2', 'LG Cleaner B', 'Limpieza',  'operador',  'Norte'),
  ('00000000-0000-0000-0000-0000000000b3', 'LG LidLimp',   'Limpieza',  'lider',     null),
  ('00000000-0000-0000-0000-0000000000b4', 'LG LidLin',    'Linens',    'lider',     null),
  ('00000000-0000-0000-0000-0000000000b5', 'LG Operacion', 'Operación', 'operacion', null);

do $$
declare
  A  text := '00000000-0000-0000-0000-0000000000b1';
  B  text := '00000000-0000-0000-0000-0000000000b2';
  LL text := '00000000-0000-0000-0000-0000000000b3';
  LN text := '00000000-0000-0000-0000-0000000000b4';
  OP text := '00000000-0000-0000-0000-0000000000b5';
  F  date := current_date - 1;   -- ayer: entra en las estadisticas de tiempos
  l1 uuid; l2 uuid; l3 uuid; q1 text; q2 text; q_viejo text; p_otro int; p_ok int;
  c int; e boolean; r text; j jsonb;
begin
  -- Preparar: 3 aptos propios de la prueba; A tiene LG1 (normal) y LG2 (refresh); B tiene LG3
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-LG1 10:00\nTEST-LG2 10:00\nTEST-LG3 11:00', true);
  perform pg_temp.yo();
  select l.id into l1 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-LG1';
  select l.id into l2 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-LG2';
  select l.id into l3 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-LG3';
  select 'OPSFLOW:' || qr_token into q1 from public.propiedades where codigo = 'TEST-LG1';
  select 'OPSFLOW:' || qr_token into q2 from public.propiedades where codigo = 'TEST-LG2';
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'normal');
  perform public.asignar_limpieza(l2, A::uuid, 2, 'refresh');
  perform public.asignar_limpieza(l3, B::uuid, 1, 'normal');
  perform public.publicar_orden(F);

  -- 1. El QR de otro apartamento no sirve; el correcto empieza y marca "con QR"
  perform pg_temp.como(A);
  r := pg_temp.error(format('select public.iniciar_con_qr(%L, %L)', l1, q2));
  perform public.iniciar_con_qr(l1, q1);
  perform pg_temp.yo();
  perform pg_temp.ok(1, 'QR de otro apto rechazado; el correcto empieza con QR',
    r like 'This QR is not for TEST-LG1%' and (select estado = 'en_curso' and inicio_qr from public.limpiezas where id = l1), r);

  -- 2. Nadie empieza la limpieza de otro, ni con el QR correcto
  perform pg_temp.como(B);
  e := pg_temp.falla(format('select public.iniciar_con_qr(%L, %L)', l2, q2));
  perform pg_temp.ok(2, 'Un cleaner no empieza la limpieza de otro', e);

  -- 3. El cleaner no puede leer los codigos QR (ni la tabla de propiedades)
  perform pg_temp.como(A);
  select count(*) into c from public.propiedades;
  e := pg_temp.falla('select * from public.qr_lista()');
  perform pg_temp.ok(3, 'El cleaner no ve los códigos QR', c = 0 and e, c::text);

  -- 4. Marcar pasos: solo de su tipo; marcar y desmarcar
  perform pg_temp.yo();
  select min(id) into p_otro from public.checklist_pasos where tipo = 'refresh';
  select min(id) into p_ok from public.checklist_pasos where tipo = 'normal';
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.marcar_paso(%L, %s, true)', l1, p_otro));
  perform public.marcar_paso(l1, p_ok, true);
  perform pg_temp.yo();
  c := (select count(*) from jsonb_object_keys((select checklist from public.limpiezas where id = l1)));
  perform pg_temp.como(A);
  perform public.marcar_paso(l1, p_ok, false);
  perform pg_temp.yo();
  perform pg_temp.ok(4, 'Solo se marcan pasos de su tipo; marcar y desmarcar funciona',
    e and c = 1 and (select checklist = '{}'::jsonb from public.limpiezas where id = l1), c::text);

  -- 5. No se termina con la checklist sin hacer
  perform pg_temp.como(A);
  r := pg_temp.error(format('select public.terminar_limpieza(%L)', l1));
  perform pg_temp.ok(5, 'Sin checklist no se puede terminar', r like 'Checklist not finished%', r);

  -- 6. Con la checklist hecha pero sin fotos, tampoco
  perform pg_temp.como(A);
  perform public.marcar_paso(l1, p.id, true) from public.checklist_pasos p where p.tipo = 'normal' and p.obligatorio;
  r := pg_temp.error(format('select public.terminar_limpieza(%L)', l1));
  perform pg_temp.ok(6, 'Sin las 4 fotos no se puede terminar', r like 'Take the 4 photos first (0 of 4)%', r);

  -- 7. Subir fotos al bucket: solo el cleaner de una limpieza en curso, en su carpeta
  perform pg_temp.como(A);
  insert into storage.objects (bucket_id, name) values ('fotos-cierre', l1 || '/bedroom.jpg');
  e := pg_temp.falla(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'fotos-cierre', l3 || '/bedroom.jpg'));
  perform pg_temp.como(B);
  e := e and pg_temp.falla(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'fotos-cierre', l1 || '/kitchen.jpg'));
  perform pg_temp.ok(7, 'Cada cleaner sube fotos solo a su limpieza en curso', e);

  -- 8. registrar_foto: no acepta rutas de otra limpieza ni salas inventadas
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.registrar_foto(%L, %L, %L)', l1, 'bedroom', l3 || '/bedroom.jpg'))
   and pg_temp.falla(format('select public.registrar_foto(%L, %L, %L)', l1, 'garage', l1 || '/garage.jpg'));
  perform public.registrar_foto(l1, s, l1 || '/' || s || '.jpg') from unnest(array['bedroom','bathroom','kitchen','living']) s;
  perform public.registrar_foto(l1, 'bedroom', l1 || '/bedroom-2.jpg');   -- repetir una foto la sustituye
  perform pg_temp.yo();
  c := (select count(*) from public.fotos_cierre where limpieza_id = l1);
  perform pg_temp.ok(8, 'Fotos: rutas ajenas rechazadas; repetir sustituye (quedan 4)', e and c = 4, c::text);

  -- 9. Con checklist + 4 fotos se termina; ya no se pueden subir mas fotos
  perform pg_temp.como(A);
  perform public.terminar_limpieza(l1);
  e := pg_temp.falla(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'fotos-cierre', l1 || '/extra.jpg'));
  perform pg_temp.yo();
  perform pg_temp.ok(9, 'Con checklist y 4 fotos termina; después no se suben más fotos',
    e and (select estado = 'terminada' from public.limpiezas where id = l1));

  -- 10. Quien ve las fotos: el cleaner y el lider de limpieza si; otro cleaner y linens no
  perform pg_temp.como(A);  c := (select count(*) from public.fotos_cierre where limpieza_id = l1);
  perform pg_temp.como(LL); c := c * 10 + (select count(*) from public.fotos_cierre where limpieza_id = l1);
  perform pg_temp.como(B);  c := c * 10 + (select count(*) from public.fotos_cierre where limpieza_id = l1);
  perform pg_temp.como(LN); c := c * 10 + (select count(*) from public.fotos_cierre where limpieza_id = l1)
                                         + (select count(*) from storage.objects where name like l1 || '/%');
  perform pg_temp.ok(10, 'Fotos visibles para su cleaner y el líder; no para otros', c = 4400, c::text);

  -- 11. "Can't scan": empieza igual, marcado sin QR
  perform pg_temp.como(A);
  perform public.iniciar_limpieza(l2);
  perform pg_temp.yo();
  perform pg_temp.ok(11, 'Can''t scan empieza marcado "sin QR"',
    (select estado = 'en_curso' and inicio_qr is false from public.limpiezas where id = l2));

  -- 12. mi_checklist: el cleaner y el lider la ven; otro cleaner no
  perform pg_temp.como(A);
  j := public.mi_checklist(l1);
  perform pg_temp.como(B);
  e := pg_temp.falla(format('select public.mi_checklist(%L)', l1));
  perform pg_temp.como(LL);
  perform pg_temp.ok(12, 'La checklist la ven su cleaner y el líder (pasos, hechos, fotos)',
    e and jsonb_array_length(j->'pasos') = (select count(*) from public.checklist_pasos where tipo = 'normal' and activo)
      and (select count(*) from jsonb_object_keys(j->'fotos')) = 4 and (j->>'inicio_qr')::boolean
      and public.mi_checklist(l1) is not null, j::text);

  -- 13. Tiempos por apto: solo lider/Operacion; cuenta solo con QR y entre 10 min y 6 h
  perform pg_temp.yo();
  update public.limpiezas set inicio = now() - interval '95 minutes', fin = now() where id = l1;
  update public.limpiezas set estado = 'terminada', inicio = now() - interval '50 minutes', fin = now() where id = l2; -- sin QR: no cuenta
  perform pg_temp.como(A);
  e := pg_temp.falla('select * from public.tiempos_aptos()');
  perform pg_temp.como(LL);
  select string_agg(codigo || ' ' || tipo || ' n=' || limpiezas || ' media=' || media_min, '; ') into r
    from public.tiempos_aptos() where codigo in ('TEST-LG1', 'TEST-LG2');
  perform pg_temp.ok(13, 'Tiempos por apto: solo líder/Operación, sin contar "sin QR"', e and r = 'TEST-LG1 normal n=1 media=95', r);

  -- 14. Tiempos por persona: solo Operacion
  perform pg_temp.como(LL);
  e := pg_temp.falla('select * from public.tiempos_personas()');
  perform pg_temp.como(OP);
  select string_agg(tipo || ' n=' || limpiezas || ' media=' || coalesce(media_min::text, '-') || ' sinQR=' || sin_qr, '; ' order by tipo) into r
    from public.tiempos_personas() where cleaner = 'LG Cleaner A';
  perform pg_temp.ok(14, 'Tiempos por persona: solo Operación', e and r = 'normal n=1 media=95 sinQR=0; refresh n=0 media=- sinQR=1', r);

  -- 15. Regenerar el QR: el viejo deja de valer
  perform pg_temp.como(OP);
  q_viejo := q2;
  perform public.regenerar_qr((select id from public.propiedades where codigo = 'TEST-LG2'));
  perform pg_temp.yo();
  update public.limpiezas set estado = 'asignada', inicio = null, fin = null where id = l2;
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.iniciar_con_qr(%L, %L)', l2, q_viejo));
  perform pg_temp.como(LL);
  e := e and pg_temp.falla(format('select public.regenerar_qr(%L)', (select propiedad_id from public.limpiezas where id = l2)));
  perform pg_temp.ok(15, 'Regenerar QR (solo Operación) invalida el anterior', e);

  -- 16. Personas: entre 1 y 4
  perform pg_temp.como(B);
  e := pg_temp.falla(format('select public.marcar_personas(%L, 5)', l3));
  perform public.marcar_personas(l3, 2);
  perform pg_temp.yo();
  perform pg_temp.ok(16, 'Personas por limpieza entre 1 y 4', e and (select personas = 2 from public.limpiezas where id = l3));

  -- 17. Fotos de mas de 30 dias: solo el servidor; devuelve las rutas y borra las filas
  perform pg_temp.como(OP);
  e := pg_temp.falla('select * from public.fotos_caducadas(30)');
  perform pg_temp.yo();
  update public.fotos_cierre set subida_en = now() - interval '31 days' where limpieza_id = l1 and sala in ('bedroom', 'kitchen');
  select count(*) into c from public.fotos_caducadas(30) x where x.ruta like l1 || '/%';
  perform pg_temp.ok(17, 'Borrado a 30 días: solo servidor, solo las viejas',
    e and c = 2 and (select count(*) from public.fotos_cierre where limpieza_id = l1) = 2, c::text);

  -- 18. Leccion de los avisos: ninguna funcion de OpsFlow tiene UPDATE/DELETE sin WHERE
  select string_agg(distinct p.proname, ', ') into r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
       lateral regexp_split_to_table(regexp_replace(lower(p.prosrc), '--[^\n]*', '', 'g'), ';') st
  where n.nspname = 'public' and p.prolang in (select oid from pg_language where lanname in ('plpgsql', 'sql'))
    and st ~ '(^|\s|\()(update\s+\S+\s+set|delete\s+from)\s' and st !~ '\swhere\s';
  perform pg_temp.ok(18, 'Ningún UPDATE/DELETE sin WHERE (Supabase los bloquea)', r is null, r);
end $$;

-- Dejarlo todo como estaba
select set_config('storage.allow_delete_query', 'true', false);  -- Supabase solo deja borrar fotos así si se pide expresamente
delete from storage.objects where bucket_id = 'fotos-cierre' and split_part(name, '/', 1) in
  (select l.id::text from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where p.codigo like 'TEST-LG_');
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-LG_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-LG_');
delete from public.propiedades where codigo like 'TEST-LG_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000b%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000b%';
delete from public.eventos where id > (select max_id from _inicio);

select * from resultados order by n;
