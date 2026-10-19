-- OpsFlow · pruebas del cierre del apartamento (limpieza guiada v3)
-- Ejecutar DESPUES de 013. Supabase → SQL Editor → pegar todo → Run.
-- Crea usuarios y apartamentos de prueba, lo deja todo como estaba y muestra una tabla: todas las filas deben decir OK.

-- Por si una ejecución anterior se cortó a medias
select set_config('storage.allow_delete_query', 'true', false);  -- Supabase solo deja borrar fotos así si se pide expresamente
delete from storage.objects where bucket_id = 'fotos-cierre' and split_part(name, '/', 1) in
  (select l.id::text from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where p.codigo like 'TEST-CZ_');
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-CZ_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-CZ_');
delete from public.propiedades where codigo like 'TEST-CZ_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000d%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000d%';

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
-- A quien avisaria el servidor (solo cuentas de esta prueba)
create function pg_temp.avisa(t text, i uuid) returns text language sql as $$
  select coalesce(string_agg(pf.nombre, ', ' order by pf.nombre), '(nadie)')
  from public.avisos_para(t, i) a join public.perfiles pf on pf.id = a.perfil_id
  where pf.id::text like '00000000-0000-0000-0000-0000000000d%'
$$;

-- 1. El departamento Bodega existe (si no, este insert falla)
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000d1', 'cz.cleanera@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d2', 'cz.cleanerb@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d3', 'cz.lidlimp@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d4', 'cz.lidbod@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d5', 'cz.lidlin@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d6', 'cz.liddrv@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d7', 'cz.drvnorte@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d8', 'cz.drvsur@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d9', 'cz.operacion@opsflow.test','authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona) values
  ('00000000-0000-0000-0000-0000000000d1', 'CZ Cleaner A',  'Limpieza',  'operador',  'Norte'),
  ('00000000-0000-0000-0000-0000000000d2', 'CZ Cleaner B',  'Limpieza',  'operador',  'Norte'),
  ('00000000-0000-0000-0000-0000000000d3', 'CZ LidLimp',    'Limpieza',  'lider',     null),
  ('00000000-0000-0000-0000-0000000000d4', 'CZ LidBodega',  'Bodega',    'lider',     null),
  ('00000000-0000-0000-0000-0000000000d5', 'CZ LidLinens',  'Linens',    'lider',     null),
  ('00000000-0000-0000-0000-0000000000d6', 'CZ LidDrivers', 'Drivers',   'lider',     null),
  ('00000000-0000-0000-0000-0000000000d7', 'CZ DrvNorte',   'Drivers',   'operador',  'Norte'),
  ('00000000-0000-0000-0000-0000000000d8', 'CZ DrvSur',     'Drivers',   'operador',  'Sur'),
  ('00000000-0000-0000-0000-0000000000d9', 'CZ Operacion',  'Operación', 'operacion', null);
insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values
  ('TEST-CZ1', 'Prueba cierre 1', 'Norte', 'Prueba', true),
  ('TEST-CZ2', 'Prueba cierre 2', 'Norte', 'Prueba', true),
  ('TEST-CZ3', 'Prueba cierre 3', 'Norte', 'Prueba', true);
insert into resultados values (1, 'Existe el departamento Bodega', 'OK');

do $$
declare
  A  text := '00000000-0000-0000-0000-0000000000d1';
  B  text := '00000000-0000-0000-0000-0000000000d2';
  LL text := '00000000-0000-0000-0000-0000000000d3';
  LB text := '00000000-0000-0000-0000-0000000000d4';
  LN text := '00000000-0000-0000-0000-0000000000d5';
  LD text := '00000000-0000-0000-0000-0000000000d6';
  DN text := '00000000-0000-0000-0000-0000000000d7';
  DS text := '00000000-0000-0000-0000-0000000000d8';
  OP text := '00000000-0000-0000-0000-0000000000d9';
  F  date := current_date - 1;
  l1 uuid; l2 uuid; l3 uuid; q1 text; q2 text; pu uuid; pb uuid; plin uuid;
  c int; e boolean; r text; r2 text; j jsonb;
begin
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-CZ1 10:00\nTEST-CZ2 10:00 15:00\nTEST-CZ3 11:00', true);
  perform pg_temp.yo();
  select l.id into l1 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-CZ1';
  select l.id into l2 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-CZ2';
  select l.id into l3 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-CZ3';
  select 'OPSFLOW:' || qr_token into q1 from public.propiedades where codigo = 'TEST-CZ1';
  select 'OPSFLOW:' || qr_token into q2 from public.propiedades where codigo = 'TEST-CZ2';
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'normal');
  perform public.asignar_limpieza(l2, A::uuid, 2, 'normal');
  perform public.asignar_limpieza(l3, B::uuid, 1, 'normal');
  perform public.publicar_orden(F);
  -- A y B empiezan con QR, hacen la checklist y las 4 fotos
  perform pg_temp.como(A);
  perform public.iniciar_con_qr(l1, q1);
  perform public.iniciar_con_qr(l2, q2);
  perform public.marcar_paso(x.l, p.id, true) from public.checklist_pasos p, (values (l1), (l2)) x(l) where p.tipo = 'normal' and p.obligatorio;
  perform public.registrar_foto(x.l, s, x.l || '/' || s || '.jpg') from unnest(array['bedroom','bathroom','kitchen','living']) s, (values (l1), (l2)) x(l);
  perform pg_temp.yo();
  update public.limpiezas set estado = 'en_curso', inicio = now(), inicio_qr = false where id = l3;

  -- 2. Sin responder las 3 preguntas no se cierra
  perform pg_temp.como(A);
  r := pg_temp.error(format('select public.cerrar_limpieza(%L, %L, null, true, true, false, true)', l1, q1));
  perform pg_temp.ok(2, 'Sin responder las 3 preguntas no se cierra', r like 'Answer the 3 closing questions%', r);

  -- 3. QR de otro apto al salir: rechazado y no se crea nada a medias
  r := pg_temp.error(format('select public.cerrar_limpieza(%L, %L, false, true, true, false, true)', l1, q2));
  perform pg_temp.yo();
  perform pg_temp.ok(3, 'QR de otro apto al salir: rechazado, sin pendientes a medias',
    r like 'This QR is not for TEST-CZ1%' and (select estado = 'en_curso' from public.limpiezas where id = l1)
    and not exists (select 1 from public.pendientes where limpieza_id = l1), r);

  -- 4. Basura sin foto: no
  perform pg_temp.como(A);
  r := pg_temp.error(format('select public.cerrar_limpieza(%L, %L, true, true, true, true, true)', l1, q1));
  perform pg_temp.ok(4, 'Basura: la foto es obligatoria', r like 'Take a photo of the trash%', r);

  -- 5. Llaves no dejadas sin motivo: no
  perform pg_temp.como(A);
  r := pg_temp.error(format('select public.cerrar_limpieza(%L, %L, true, true, true, false, false, %L)', l1, q1, ' '));
  perform pg_temp.ok(5, 'Llaves NO en key box: el motivo es obligatorio', r like 'Write why the keys%', r);

  -- 6. Cierre completo: faltan escoba y recogedor, queda basura (con foto), llaves no dejadas
  perform pg_temp.como(A);
  insert into storage.objects (bucket_id, name) values ('fotos-cierre', l1 || '/basura.jpg');
  perform public.registrar_foto(l1, 'basura', l1 || '/basura.jpg');
  j := public.cerrar_limpieza(l1, q1, false, true, false, true, false, 'Guest kept them');
  perform pg_temp.yo();
  select into pu id from public.pendientes where limpieza_id = l1 and tipo::text = 'utiles';
  select into pb id from public.pendientes where limpieza_id = l1 and tipo::text = 'recogida';
  perform pg_temp.ok(6, 'Cierre: terminada con QR de salida, útiles y basura creados, llaves registradas',
    jsonb_array_length(j->'pendientes') = 2
    and (select estado = 'terminada' and fin_qr and cierre->>'llaves' = 'false' and cierre->>'motivo_llaves' = 'Guest kept them'
                and cierre->>'escoba' = 'false' and cierre->>'squeegee' = 'true' from public.limpiezas where id = l1)
    and (select detalle = 'Falta: escoba, recogedor' and cantidad = 2 and estado = 'abierto' from public.pendientes where id = pu)
    and (select foto = l1 || '/basura.jpg' and estado = 'abierto' from public.pendientes where id = pb), j::text);

  -- 7. "Can't scan" al salir: termina marcado salida sin QR, sin pendientes si todo esta bien
  perform pg_temp.como(A);
  perform public.cerrar_limpieza(l2, null, true, true, true, false, true);
  perform pg_temp.yo();
  perform pg_temp.ok(7, 'Can''t scan al salir: termina marcado "salida sin QR"',
    (select estado = 'terminada' and fin_qr is false from public.limpiezas where id = l2)
    and not exists (select 1 from public.pendientes where limpieza_id = l2));

  -- 8. El Finish antiguo ya no cierra
  perform pg_temp.como(B);
  r := pg_temp.error(format('select public.terminar_limpieza(%L)', l3));
  perform pg_temp.ok(8, 'El Finish antiguo ya no cierra (obliga a pasar por el cierre)', r like 'Update the app%', r);

  -- 9. Quien ve el pendiente de utiles
  perform pg_temp.como(LB); c := (select count(*) from public.pendientes where limpieza_id = l1);
  perform pg_temp.como(LN); c := c * 10 + (select count(*) from public.pendientes where id = pu);
  perform pg_temp.como(DN); c := c * 10 + (select count(*) from public.pendientes where id = pu);
  perform pg_temp.como(LD); c := c * 10 + (select count(*) from public.pendientes where limpieza_id = l1);
  perform pg_temp.ok(9, 'Útiles: los ve bodega (no la basura); linens no; driver aún no; líder drivers ve los 2', c = 1002, c::text);

  -- 10. Preparar utiles: solo bodega (u Operacion); bodega no prepara linens
  perform pg_temp.como(B);
  plin := public.reportar_pendiente(l3, 'linens', 'Large towel', 1);
  perform pg_temp.como(LN);
  e := pg_temp.falla(format('select public.marcar_preparado(%L)', pu));
  perform pg_temp.como(LB);
  e := e and pg_temp.falla(format('select public.marcar_preparado(%L)', plin));
  perform pg_temp.como(DN);
  e := e and pg_temp.falla(format('select public.marcar_entregado(%L)', pu));   -- el driver no entrega lo que bodega no ha preparado
  perform pg_temp.como(LB);
  perform public.marcar_preparado(pu);
  perform pg_temp.yo();
  perform pg_temp.ok(10, 'Útiles: los prepara bodega (linens no; bodega no prepara linens); el driver no entrega antes',
    e and (select estado = 'preparado' from public.pendientes where id = pu));

  -- 11. Ruta del driver: ve útiles preparados y la basura con foto; el de otra zona no; entregar cierra los útiles
  perform pg_temp.como(DN);
  j := public.mi_ruta(F);
  r := (select string_agg(t->>'tipo' || coalesce(':' || (t->>'foto'), ''), ', ' order by t->>'tipo') from jsonb_array_elements(j->'tareas') t
        where t->>'codigo' = 'TEST-CZ1');
  perform pg_temp.como(DS);
  c := (select count(*) from jsonb_array_elements(public.mi_ruta(F)->'tareas') t where t->>'codigo' like 'TEST-CZ%');
  perform pg_temp.como(DN);
  perform public.marcar_entregado(pu);
  perform public.marcar_entregado(pb);
  perform pg_temp.yo();
  perform pg_temp.ok(11, 'Driver de la zona: ve útiles y basura (con foto) y los cierra; otra zona no',
    r = 'recogida:' || l1 || '/basura.jpg, utiles' and c = 0
    and (select count(*) = 2 from public.pendientes where id in (pu, pb) and estado = 'cerrado'), coalesce(r, '(nada)') || ' / otra zona ' || c);

  -- 12. Foto de la basura: la ven el driver de la zona y el lider de drivers; no el de otra zona; el driver no ve las demas fotos
  perform pg_temp.como(DN); c := (select count(*) from storage.objects where name = l1 || '/basura.jpg')
                                 + (select count(*) from public.fotos_cierre where limpieza_id = l1);
  perform pg_temp.como(LD); c := c * 10 + (select count(*) from storage.objects where name = l1 || '/basura.jpg');
  perform pg_temp.como(DS); c := c * 10 + (select count(*) from storage.objects where name = l1 || '/basura.jpg')
                                         + (select count(*) from public.fotos_cierre where limpieza_id = l1);
  perform pg_temp.ok(12, 'Foto de la basura: driver de la zona y líder de drivers sí; otra zona no; el resto de fotos no', c = 210, c::text);

  -- 13. Avisos: a quien llega cada cosa
  perform pg_temp.yo();
  update public.pendientes set estado = 'abierto' where id in (pu, pb);
  r := pg_temp.avisa('pendiente', pu);
  update public.pendientes set estado = 'preparado' where id = pu;
  r := r || ' | ' || pg_temp.avisa('pendiente', pu) || ' | ' || pg_temp.avisa('pendiente', pb) || ' | ' || pg_temp.avisa('limpieza', l1)
         || ' | ' || pg_temp.avisa('limpieza', l2);
  update public.pendientes set estado = 'cerrado' where id in (pu, pb);
  perform pg_temp.ok(13, 'Avisos: útiles→bodega→driver zona; basura→driver zona+líder drivers; llaves→líderes',
    r = 'CZ LidBodega | CZ DrvNorte | CZ DrvNorte, CZ LidDrivers | CZ LidDrivers, CZ LidLimp | (nadie)', r);

  -- 14. Tiempos: solo cuentan las de QR al entrar Y al salir
  perform pg_temp.yo();
  update public.limpiezas set inicio = now() - interval '95 minutes' where id in (l1, l2);
  perform pg_temp.como(LL);
  select string_agg(codigo || ' n=' || limpiezas || ' media=' || media_min, '; ') into r from public.tiempos_aptos() where codigo like 'TEST-CZ%';
  perform pg_temp.como(OP);
  select string_agg('n=' || limpiezas || ' sinQR=' || sin_qr, '; ') into r2 from public.tiempos_personas() where cleaner = 'CZ Cleaner A';
  perform pg_temp.ok(14, 'Tiempos: la limpieza con salida sin QR no cuenta (y sale como sin QR)',
    r = 'TEST-CZ1 n=1 media=95' and r2 = 'n=1 sinQR=1', coalesce(r, '-') || ' / ' || coalesce(r2, '-'));

  -- 15. Tablero: llaves no dejadas y utiles en bodega
  perform pg_temp.como(OP);
  j := public.tablero(F);
  perform pg_temp.ok(15, 'Tablero muestra las llaves NO dejadas',
    exists (select 1 from jsonb_array_elements(j->'llaves_no') x where x->>'codigo' = 'TEST-CZ1' and x->>'motivo' = 'Guest kept them'), j::text);

  -- 16. Ninguna funcion de OpsFlow tiene UPDATE/DELETE sin WHERE
  perform pg_temp.yo();
  select string_agg(distinct p.proname, ', ') into r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
       lateral regexp_split_to_table(regexp_replace(lower(p.prosrc), '--[^\n]*', '', 'g'), ';') st
  where n.nspname = 'public' and p.prolang in (select oid from pg_language where lanname in ('plpgsql', 'sql'))
    and st ~ '(^|\s|\()(update\s+\S+\s+set|delete\s+from)\s' and st !~ '\swhere\s';
  perform pg_temp.ok(16, 'Ningún UPDATE/DELETE sin WHERE (Supabase los bloquea)', r is null, r);
end $$;

-- Dejarlo todo como estaba
select set_config('storage.allow_delete_query', 'true', false);  -- Supabase solo deja borrar fotos así si se pide expresamente
delete from storage.objects where bucket_id = 'fotos-cierre' and split_part(name, '/', 1) in
  (select l.id::text from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where p.codigo like 'TEST-CZ_');
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-CZ_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-CZ_');
delete from public.propiedades where codigo like 'TEST-CZ_';
delete from public.avisos_enviados where id > (select max_av from _inicio);
delete from public.eventos where id > (select max_ev from _inicio);
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000d%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000d%';

select * from resultados order by n;
