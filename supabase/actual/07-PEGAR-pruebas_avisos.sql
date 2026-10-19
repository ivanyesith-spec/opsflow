-- OpsFlow · pruebas del modulo avisos
-- Ejecutar DESPUES de 006. Supabase → SQL Editor → pegar todo → Run.
-- Crea usuarios de prueba, recorre la cadena, comprueba quien recibe cada aviso,
-- lo deja todo como estaba y muestra una tabla: todas las filas deben decir OK.

create temp table resultados (n int, prueba text, resultado text);

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
-- Quien recibe (nombres ordenados) y el primer titulo
create function pg_temp.quien(t text, i uuid, f date default null) returns text language sql as $$
  select coalesce(string_agg(p.nombre || ' | ' || a.titulo, ' ; ' order by p.nombre), '(nadie)')
  from public.avisos_para(t, i, f) a join public.perfiles p on p.id = a.perfil_id
$$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'av.cleanera@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a2', 'av.cleanerb@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a3', 'av.drivern@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a4', 'av.drivers@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a5', 'av.drivernoff@opsflow.test','authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a6', 'av.lidlimp@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a7', 'av.lidlin@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a8', 'av.liddrv@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a9', 'av.operacion@opsflow.test','authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona, idioma, activo) values
  ('00000000-0000-0000-0000-0000000000a1', 'AV Cleaner A',   'Limpieza',  'operador',  'Norte', 'en', true),
  ('00000000-0000-0000-0000-0000000000a2', 'AV Cleaner B',   'Limpieza',  'operador',  'Norte', 'en', true),
  ('00000000-0000-0000-0000-0000000000a3', 'AV Driver N',    'Drivers',   'operador',  'Norte', 'en', true),
  ('00000000-0000-0000-0000-0000000000a4', 'AV Driver S',    'Drivers',   'operador',  'Sur',   'en', true),
  ('00000000-0000-0000-0000-0000000000a5', 'AV Driver N off','Drivers',   'operador',  'Norte', 'en', false),
  ('00000000-0000-0000-0000-0000000000a6', 'AV LidLimp',     'Limpieza',  'lider',     null,    'es', true),
  ('00000000-0000-0000-0000-0000000000a7', 'AV LidLin',      'Linens',    'lider',     null,    'es', true),
  ('00000000-0000-0000-0000-0000000000a8', 'AV LidDrv',      'Drivers',   'lider',     null,    'es', true),
  ('00000000-0000-0000-0000-0000000000a9', 'AV Operacion',   'Operación', 'operacion', null,    'es', true);

do $$
declare
  A  text := '00000000-0000-0000-0000-0000000000a1';
  B  text := '00000000-0000-0000-0000-0000000000a2';
  DN text := '00000000-0000-0000-0000-0000000000a3';
  DX text := '00000000-0000-0000-0000-0000000000a5';
  LL text := '00000000-0000-0000-0000-0000000000a6';
  LN text := '00000000-0000-0000-0000-0000000000a7';
  OP text := '00000000-0000-0000-0000-0000000000a9';
  F  date := '2099-03-01';
  EP text := 'https://push.example.test/av-telefono-a';
  K1 text := 'BPrueba-clave-publica-del-telefono-aaaaaaaaaaaaaaaaaaaaaaaa';
  K2 text := 'secreto-prueba-1234';
  l1 uuid; l2 uuid; l3 uuid; pl uuid; pr uuid; po uuid;
  c int; e boolean; r text; j jsonb;
begin
  -- 1. Cada uno guarda su telefono y ve que tiene avisos
  perform pg_temp.como(A);
  perform public.guardar_suscripcion(EP, K1, K2, 'iPhone');
  c := public.mis_avisos();
  perform pg_temp.ok(1, 'El cleaner guarda su teléfono (mis_avisos = 1)', c = 1, c::text);

  -- 2. Nadie lee ni escribe las tablas de avisos directamente
  perform pg_temp.como(OP);
  e := pg_temp.falla('select 1 from public.suscripciones limit 1')
   and pg_temp.falla('select 1 from public.avisos_enviados limit 1')
   and pg_temp.falla(format('insert into public.suscripciones (perfil_id, endpoint, p256dh, auth) values (%L, ''https://x.test/1'', %L, %L)', OP, K1, K2));
  perform pg_temp.ok(2, 'Ni Operación lee o escribe directo las suscripciones', e);

  -- 3. Borrar el telefono de otro no hace nada
  perform pg_temp.como(B);
  perform public.borrar_suscripcion(EP);
  perform pg_temp.yo();
  select count(*) into c from public.suscripciones where endpoint = EP;
  perform pg_temp.ok(3, 'Nadie puede borrar el teléfono de otro', c = 1, c::text);

  -- 4. Una cuenta desactivada no puede activar avisos
  perform pg_temp.como(DX);
  e := pg_temp.falla(format('select public.guardar_suscripcion(%L, %L, %L)', 'https://push.example.test/off', K1, K2));
  perform pg_temp.ok(4, 'Una cuenta desactivada no activa avisos', e);

  -- 5. Desde la app nadie puede pedir la lista de destinatarios
  perform pg_temp.como(OP);
  e := pg_temp.falla('select * from public.avisos_para(''orden'', null, ''2099-03-01'')');
  perform pg_temp.ok(5, 'Solo el servidor calcula a quién avisar', e);

  -- Preparar el dia: 3 checkouts (N01 con check-in), A tiene N01 y N02, B tiene N03
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-N01 10:00 15:00\nTEST-N02 10:00\nTEST-N03 11:00', true);
  perform pg_temp.yo();
  select l.id into l1 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-N01';
  select l.id into l2 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-N02';
  select l.id into l3 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-N03';
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'normal');
  perform public.asignar_limpieza(l3, B::uuid, 1, 'normal');
  perform public.publicar_orden(F);
  perform pg_temp.yo();

  -- 6. Orden publicado → cada cleaner con lo suyo; repetir no vuelve a sonar
  r := pg_temp.quien('orden', null, F);
  perform pg_temp.ok(6, 'Orden publicado avisa a los 2 cleaners', r = 'AV Cleaner A | Your cleaning order is ready ; AV Cleaner B | Your cleaning order is ready', r);
  r := pg_temp.quien('orden', null, F);
  perform pg_temp.ok(7, 'Publicar otra vez sin cambios no repite el aviso', r = '(nadie)', r);

  -- 8. Si el lider le añade otra y publica, solo le suena a ese cleaner
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l2, A::uuid, 2, 'normal');
  perform public.publicar_orden(F);
  perform pg_temp.yo();
  select count(*), max(x.cuerpo), max(jsonb_array_length(x.telefonos)) into c, r, j
    from public.avisos_para('orden', null, F) x where x.perfil_id = A::uuid;
  perform pg_temp.ok(8, 'Añadir una limpieza vuelve a avisar solo a ese cleaner, con su teléfono',
    c = 1 and r = '01/03 · 2 apartments' and j = '1'::jsonb, c || ' ' || coalesce(r, '') || ' ' || coalesce(j::text, ''));

  -- 9. Linens reportado (con check-in) → solo el lider de linens, en español y con ⚠
  perform pg_temp.como(A);
  perform public.iniciar_limpieza(l1);
  pl := public.reportar_pendiente(l1, 'linens', 'Large towel', 2);
  perform pg_temp.yo();
  r := pg_temp.quien('pendiente', pl);
  perform pg_temp.ok(9, 'Linens reportado → líder de linens (⚠ por check-in)', r = 'AV LidLin | ⚠ Linens: 2 × Large towel', r);

  -- 10. Preparado → solo el driver activo de esa zona
  perform pg_temp.como(LN);
  perform public.marcar_preparado(pl);
  perform pg_temp.yo();
  select string_agg(p.nombre || ' | ' || x.titulo || ' | ' || x.cuerpo, ' ; ') into r
    from public.avisos_para('pendiente', pl) x join public.perfiles p on p.id = x.perfil_id;
  perform pg_temp.ok(10, 'Preparado → driver de Norte (no Sur, no desactivado)',
    r = 'AV Driver N | ⚠ Deliver: 2 × Large towel | TEST-N01 · ' || (select pueblo from public.propiedades where codigo = 'TEST-N01') || ' · Guest arrives 15:00', r);

  -- 11. Entregado → el cleaner que lo pidio
  perform pg_temp.como(DN);
  perform public.marcar_entregado(pl);
  perform pg_temp.yo();
  r := pg_temp.quien('pendiente', pl);
  perform pg_temp.ok(11, 'Entregado → el cleaner que lo pidió', r = 'AV Cleaner A | ⚠ Delivered: 2 × Large towel', r);

  -- 12. Recibido (cerrado) → no avisa a nadie
  perform pg_temp.como(A);
  perform public.marcar_recibido(pl);
  perform pg_temp.yo();
  r := pg_temp.quien('pendiente', pl);
  perform pg_temp.ok(12, 'Un pendiente cerrado no avisa', r = '(nadie)', r);

  -- 13. Recogida → driver de la zona
  perform pg_temp.como(A);
  pr := public.reportar_pendiente(l1, 'recogida', null, 1);
  perform pg_temp.yo();
  r := pg_temp.quien('pendiente', pr);
  perform pg_temp.ok(13, 'Recogida → driver de Norte', r = 'AV Driver N | ⚠ Pick up: trash & dirty linens', r);

  -- 14. Pendiente "otro" → lider de limpieza
  perform pg_temp.como(A);
  perform public.iniciar_limpieza(l2);
  po := public.reportar_pendiente(l2, 'otro', 'Broken kettle', 1);
  perform pg_temp.yo();
  r := pg_temp.quien('pendiente', po);
  perform pg_temp.ok(14, 'Pendiente "otro" → líder de limpieza', r = 'AV LidLimp | Pendiente: Broken kettle', r);

  -- 15. No pude entrar → lider de limpieza, lider de drivers y driver de la zona
  perform pg_temp.como(B);
  perform public.no_pude_entrar(l3, 'Wrong door code');
  perform pg_temp.yo();
  r := pg_temp.quien('limpieza', l3);
  perform pg_temp.ok(15, 'No pude entrar → líder limpieza, líder drivers y driver de Norte',
    r = 'AV Driver N | Couldn''t get in: TEST-N03 ; AV LidDrv | No pudo entrar: TEST-N03 ; AV LidLimp | No pudo entrar: TEST-N03', r);

  -- 16. Una limpieza normal no avisa; el mismo aviso nunca sale dos veces
  r := pg_temp.quien('limpieza', l2) || ' / ' || pg_temp.quien('limpieza', l3) || ' / ' || pg_temp.quien('pendiente', pr);
  perform pg_temp.ok(16, 'Sin aviso si no toca, y nunca dos veces el mismo', r = '(nadie) / (nadie) / (nadie)', r);

  -- 17. El dueño borra su propio telefono
  perform pg_temp.como(A);
  perform public.borrar_suscripcion(EP);
  c := public.mis_avisos();
  perform pg_temp.ok(17, 'El cleaner quita su teléfono', c = 0, c::text);
end $$;

-- Dejarlo todo como estaba
delete from public.avisos_enviados where perfil_id::text like '00000000-0000-0000-0000-0000000000a%';
delete from public.suscripciones   where perfil_id::text like '00000000-0000-0000-0000-0000000000a%';
delete from public.checkouts where fecha = '2099-03-01';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000a%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000a%';

select * from resultados order by n;
