-- OpsFlow · 35 · Pruebas de 34-PEGAR-permisos_sustituciones.sql (asignación solo por líderes + sustituciones)
-- Ejecutar DESPUÉS de la 34, en el MISMO proyecto de PRUEBAS. Supabase → SQL Editor → pegar todo → Run.
-- Todas las filas deben decir OK.
--
-- NO DEJA NADA: todas las pruebas se hacen dentro de un bloque que al final se deshace entero
-- (usuarios, propiedades, limpiezas, eventos, avisos…). No se borra nada después, así que no puede
-- tocar datos de otras personas que estén usando el proyecto de pruebas a la vez.
-- Las pruebas de "no puede" comprueban el código de error y el motivo exacto: cualquier otro error es FALLO.

-- ✏️ ESCRIBE AQUÍ el identificador del proyecto de PRUEBAS (el mismo que en la 34)
select set_config('opsflow.proyecto', 'ESCRIBE-AQUI-EL-ID-DEL-PROYECTO', false);

do $$
declare v text := current_setting('opsflow.proyecto', true); v_tipo text; v_proy text;
begin
  if v is null or v !~ '^[a-z]{20}$' then
    raise exception 'PARADO: escribe en la primera línea el identificador del proyecto de pruebas (20 letras minúsculas).';
  end if;
  if v = 'zxsiantglodsqqvigndk' then raise exception 'PARADO: ese identificador es el de PRODUCCIÓN.'; end if;
  if to_regclass('public.opsflow_entorno') is not null then
    execute 'select tipo, proyecto from public.opsflow_entorno where id = 1' into v_tipo, v_proy;
  end if;
  if v_tipo is distinct from 'pruebas' then raise exception 'PARADO: esta base de datos no tiene la marca de entorno de PRUEBAS.'; end if;
  if v_proy <> v then raise exception 'PARADO: escribiste % pero este proyecto está marcado como %.', v, v_proy; end if;
  if to_regclass('public.sustituciones') is null or to_regprocedure('public._es_lider(text)') is null then
    raise exception 'Falta la migración 34: pega primero 34-PEGAR-permisos_sustituciones.sql.';
  end if;
end $$;

create temp table if not exists resultados (n int, prueba text, resultado text);
truncate resultados;

-- Ayudantes de la prueba (temporales: desaparecen al cerrar la sesión)
create or replace function pg_temp.como(uid text) returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.yo() returns void language plpgsql as $$
begin perform set_config('role', 'none', true); end $$;
-- Ejecuta q: null si funciona; si falla, 'CODIGO: mensaje'
create or replace function pg_temp.error_de(q text) returns text language plpgsql as $$
begin execute q; return null;
exception when others then return sqlstate || ': ' || sqlerrm; end $$;
-- ¿Falla con ESE código y un mensaje que contiene ESE texto?
create or replace function pg_temp.deniega(q text, cod text, motivo text) returns text language plpgsql as $$
declare e text := pg_temp.error_de(q);
begin
  if e is null then return 'NO falló (se esperaba ' || cod || ')'; end if;
  if e like cod || ': %' || motivo || '%' then return null; end if;
  return 'falló por otra razón: ' || e;
end $$;
-- Una fila de resultado como jsonb (se guarda en una variable, que NO se deshace)
create or replace function pg_temp.r(n int, prueba text, cond boolean, detalle text default '') returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('n', n, 'prueba', prueba,
    'resultado', case when coalesce(cond, false) then 'OK' else 'FALLO ' || coalesce(detalle, '') end)) $$;
create or replace function pg_temp.r2(n int, prueba text, fallos text[]) returns jsonb language sql as $$
  select pg_temp.r(n, prueba, coalesce(array_length(array_remove(fallos, null), 1), 0) = 0,
                   array_to_string(array_remove(fallos, null), ' | ')) $$;

do $$
declare
  LL text := '00000000-0000-0000-0000-000000003401';   -- líder de limpieza
  CA text := '00000000-0000-0000-0000-000000003402';   -- cleaner
  CB text := '00000000-0000-0000-0000-000000003403';   -- cleaner (será sustituto de limpieza)
  LD text := '00000000-0000-0000-0000-000000003404';   -- líder de drivers
  DR text := '00000000-0000-0000-0000-000000003405';   -- driver
  OP text := '00000000-0000-0000-0000-000000003406';   -- Operación
  D2 text := '00000000-0000-0000-0000-000000003407';   -- driver (será sustituto de drivers)
  LN text := '00000000-0000-0000-0000-000000003408';   -- operador de linens
  F  date := (now() at time zone 'Europe/Malta')::date;
  R  jsonb := '[]';
  l1 uuid; pe uuid; pe2 uuid; po uuid; s1 uuid; s2 uuid; s3 uuid; n int; x text; j jsonb; b boolean;
begin
  begin   -- ── todo lo de dentro se deshace al final ──
    insert into auth.users (id, email, aud, role)
    select u::uuid, 'pm' || right(u, 2) || '@opsflow.test', 'authenticated', 'authenticated' from unnest(array[LL, CA, CB, LD, DR, OP, D2, LN]) u;
    insert into public.perfiles (id, nombre, departamento, nivel, zona, idioma) values
      (LL::uuid, 'PM LidLimp',   'Limpieza',  'lider',     null,    'es'),
      (CA::uuid, 'PM Ana',       'Limpieza',  'operador',  'Norte', 'en'),
      (CB::uuid, 'PM Beto',      'Limpieza',  'operador',  'Norte', 'en'),
      (LD::uuid, 'PM LidDrv',    'Drivers',   'lider',     null,    'es'),
      (DR::uuid, 'PM Driver',    'Drivers',   'operador',  'Norte', 'en'),
      (OP::uuid, 'PM Operacion', 'Operación', 'operacion', null,    'es'),
      (D2::uuid, 'PM Driver2',   'Drivers',   'operador',  'Norte', 'en'),
      (LN::uuid, 'PM Linens',    'Linens',    'operador',  'Norte', 'en');
    insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values ('TEST-PM1', 'Prueba permisos 1', 'Norte', 'Prueba', true);

    -- Operación sigue cargando checkouts (no es asignar personal)
    perform pg_temp.como(OP);
    perform public.cargar_checkouts(F, 'TEST-PM1 10:00', true);
    perform pg_temp.yo();
    select l.id into l1 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where p.codigo = 'TEST-PM1' and l.fecha = F;

    -- 1-2. Operación ya no asigna cleaners, ni publica, ni forma/deshace equipos, ni fija la entrada
    perform pg_temp.como(OP);
    R := R || pg_temp.r2(1, 'Operación NO asigna una limpieza (42501)', array[
      pg_temp.deniega(format('select public.asignar_limpieza(%L, %L, 1, %L)', l1, CA, 'normal'), '42501', 'Solo el líder de limpieza')]);
    R := R || pg_temp.r2(2, 'Operación NO publica, NO forma/deshace equipos, NO fija la entrada (42501)', array[
      pg_temp.deniega(format('select public.publicar_orden(%L)', F), '42501', 'publica el orden'),
      pg_temp.deniega(format('select public.guardar_equipo(array[%L, %L]::uuid[])', CA, CB), '42501', 'forma equipos'),
      pg_temp.deniega(format('select public.deshacer_equipo(%L)', gen_random_uuid()), '42501', 'deshace equipos'),
      pg_temp.deniega(format('select public.fijar_entrada(%L, %L, %L)', F, CA, '11:00'), '42501', 'fija la hora de entrada')]);

    -- 3. El líder de limpieza sí asigna y publica
    perform pg_temp.como(LL);
    perform public.asignar_limpieza(l1, CA::uuid, 1, 'normal');
    n := public.publicar_orden(F);
    perform pg_temp.yo();
    R := R || pg_temp.r(3, 'Líder de limpieza asigna y publica',
      (select asignada_a::text = CA and publicada from public.limpiezas where id = l1), n::text);

    -- 4. Otro líder (Drivers) no asigna limpiezas
    perform pg_temp.como(LD);
    R := R || pg_temp.r2(4, 'Líder de drivers NO asigna limpiezas (42501)', array[
      pg_temp.deniega(format('select public.asignar_limpieza(%L, %L, 1, %L)', l1, CB, 'normal'), '42501', 'Solo el líder de limpieza')]);

    -- 5-6. Drivers: Operación y el líder de limpieza NO asignan; el líder de drivers sí
    perform pg_temp.yo();
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, creado_por, es_prueba)
    select l1, propiedad_id, zona, fecha, 'recogida', 'Basura', 1, CA::uuid, true from public.limpiezas where id = l1 returning id into pe;
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, creado_por, es_prueba)
    select l1, propiedad_id, zona, fecha, 'recogida', 'Basura 2', 1, CA::uuid, true from public.limpiezas where id = l1 returning id into pe2;
    perform pg_temp.como(OP);
    x := pg_temp.deniega(format('select public.asignar_tarea(%L, %L)', pe, DR), '42501', 'Solo el líder de drivers');
    perform pg_temp.como(LL);
    R := R || pg_temp.r2(5, 'Operación y líder de limpieza NO asignan drivers (42501)', array[x,
      pg_temp.deniega(format('select public.asignar_tarea(%L, %L)', pe, DR), '42501', 'Solo el líder de drivers')]);
    perform pg_temp.como(LD);
    perform public.asignar_tarea(pe, DR::uuid);
    perform pg_temp.yo();
    R := R || pg_temp.r(6, 'Líder de drivers asigna la tarea', (select tomado_por::text = DR from public.pendientes where id = pe));

    -- 7. Soltar una tarea ASIGNADA por el líder: ni Operación ni el driver; el líder sí
    perform pg_temp.como(OP);
    x := pg_temp.deniega(format('select public.soltar_tarea(%L)', pe), '42501', 'Solo el driver que la cogió');
    perform pg_temp.como(DR);
    j := to_jsonb(pg_temp.deniega(format('select public.soltar_tarea(%L)', pe), '42501', 'la asignó el líder'));
    perform pg_temp.como(LD);
    perform public.soltar_tarea(pe);
    perform pg_temp.yo();
    R := R || pg_temp.r2(7, 'Tarea asignada por el líder: Operación y el driver NO la sueltan (42501); el líder sí', array[x, j #>> '{}',
      case when (select tomado_por from public.pendientes where id = pe) is null then null else 'el líder no pudo soltarla' end]);

    -- 8. Un driver coge trabajo libre del tablero y lo suelta él mismo
    perform pg_temp.como(DR);
    perform public.tomar_tarea(pe2);
    perform public.soltar_tarea(pe2);
    perform pg_temp.yo();
    R := R || pg_temp.r(8, 'Driver coge una tarea libre y la suelta él mismo',
      (select tomado_por is null and asignado_por is null from public.pendientes where id = pe2));

    -- 9. Solo Operación nombra sustitutos
    perform pg_temp.como(LL);
    x := pg_temp.deniega(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Limpieza', CB, '1 hour', 'Prueba'), '42501', 'Solo Operación nombra');
    perform pg_temp.como(CA);
    R := R || pg_temp.r2(9, 'Líder y operador NO nombran sustitutos (42501)', array[x,
      pg_temp.deniega(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Limpieza', CB, '1 hour', 'Prueba'), '42501', 'Solo Operación nombra')]);

    -- 10. Datos no válidos (22023): driver para limpieza, un líder, fechas al revés, departamento raro, sin motivo
    perform pg_temp.como(OP);
    R := R || pg_temp.r2(10, 'Rechaza datos no válidos con 22023 y el motivo', array[
      pg_temp.deniega(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Limpieza', DR, '1 hour', 'Prueba'), '22023', 'operador activo de Limpieza'),
      pg_temp.deniega(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Limpieza', LL, '1 hour', 'Prueba'), '22023', 'operador activo de Limpieza'),
      pg_temp.deniega(format('select public.nombrar_sustituto(%L, %L, now() + interval %L, now(), %L)', 'Limpieza', CB, '1 hour', 'Prueba'), '22023', 'posterior a "desde"'),
      pg_temp.deniega(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Bodega', CB, '1 hour', 'Prueba'), '22023', 'Departamento no válido'),
      pg_temp.deniega(format('select public.nombrar_sustituto(%L, %L, now(), now() + interval %L, %L)', 'Limpieza', CB, '1 hour', ' '), '22023', 'Escribe el motivo')]);

    -- 11. Sustituto vigente de Limpieza: asigna, SIGUE siendo operador y conserva su "Mi día"
    perform pg_temp.como(OP);
    s1 := public.nombrar_sustituto('Limpieza', CB::uuid, now() - interval '1 minute', now() + interval '2 hours', 'Vacaciones de la líder');
    perform pg_temp.como(LL);
    perform public.asignar_limpieza(l1, CB::uuid, 1, 'normal');
    n := public.publicar_orden(F);
    perform pg_temp.como(CB);
    perform public.asignar_limpieza(l1, CB::uuid, 1, 'normal');   -- el sustituto asigna
    R := R || pg_temp.r(11, 'Sustituto de limpieza: asigna, sigue siendo operador y conserva su "Mi día"',
      public.mi_nivel() = 'operador' and public._es_lider('Limpieza')
      and jsonb_array_length(public.mi_dia(F)) = 1
      and (select count(*) from public.perfiles where departamento = 'Limpieza') >= 3,
      coalesce(public.mi_nivel()::text, '-') || ' / ' || coalesce(jsonb_array_length(public.mi_dia(F))::text, '-'));

    -- 12. …pero nada fuera de su departamento: ni asignar drivers, ni preparar bolsas de Linens, ni ver las rutas
    R := R || pg_temp.r2(12, 'Sustituto de limpieza NO asigna drivers ni hace cosas de Linens/Drivers', array[
      pg_temp.deniega(format('select public.asignar_tarea(%L, %L)', pe, DR), '42501', 'Solo el líder de drivers'),
      pg_temp.deniega(format('select public.preparar_bolsa(%L)', gen_random_uuid()), 'P0001', 'Solo linens u Operación'),
      pg_temp.deniega('select public.rutas_hoy()', 'P0001', 'Solo el líder de drivers'),
      case when (select count(*) from public.perfiles where departamento = 'Drivers') = 0 then null else 've perfiles de Drivers' end]);

    -- 13. Sustituto de Drivers: asigna tareas y SIGUE trabajando de driver (coge trabajo, ve su ruta)
    perform pg_temp.como(OP);
    s3 := public.nombrar_sustituto('Drivers', D2::uuid, now() - interval '1 minute', now() + interval '2 hours', 'Líder de baja');
    perform pg_temp.como(D2);
    perform public.asignar_tarea(pe, DR::uuid);
    perform public.tomar_tarea(pe2);
    x := pg_temp.error_de(format('select public.mi_ruta(%L)', F));
    perform pg_temp.yo();
    R := R || pg_temp.r(13, 'Sustituto de drivers: asigna y sigue cogiendo trabajo y viendo su ruta',
      (select tomado_por::text = DR from public.pendientes where id = pe) and (select tomado_por::text = D2 from public.pendientes where id = pe2)
      and x is null, coalesce(x, ''));

    -- 14. Sin solapes: la función lo rechaza (23P01) y la tabla también, aunque se inserte a mano
    perform pg_temp.como(OP);
    x := pg_temp.deniega(format('select public.nombrar_sustituto(%L, %L, now() + interval %L, now() + interval %L, %L)', 'Limpieza', CA, '1 hour', '3 hours', 'Otra'), '23P01', 'Ya hay un sustituto de Limpieza');
    perform pg_temp.yo();
    R := R || pg_temp.r2(14, 'No se solapan dos sustitutos del mismo departamento (función y tabla, 23P01)', array[x,
      pg_temp.deniega(format('insert into public.sustituciones (departamento, sustituto, desde, hasta, motivo, nombrado_por) values (%L, %L, now(), now() + interval %L, %L, %L)', 'Limpieza', CA, '1 hour', 'A mano', OP), '23P01', 'sustituciones_sin_solape')]);

    -- 15. Sustitución programada (empieza más tarde): hasta entonces es un operador normal
    perform pg_temp.como(OP);
    s2 := public.nombrar_sustituto('Linens', LN::uuid, now() + interval '1 day', now() + interval '2 days', 'Vacaciones');
    perform pg_temp.como(LN);
    R := R || pg_temp.r(15, 'Sustitución programada: sigue siendo operador sin facultades de líder',
      public.mi_nivel() = 'operador' and not public._es_lider('Linens') and public.mi_sustitucion() is null);

    -- 16. Revocada: deja de asignar al momento
    perform pg_temp.como(OP);
    perform public.revocar_sustitucion(s1);
    perform pg_temp.como(CB);
    R := R || pg_temp.r2(16, 'Revocada: ya no asigna (42501)', array[
      pg_temp.deniega(format('select public.asignar_limpieza(%L, %L, 1, %L)', l1, CA, 'normal'), '42501', 'Solo el líder de limpieza')]);

    -- 17. La lista es solo de Operación
    perform pg_temp.como(OP);
    j := public.sustituciones_lista();
    perform pg_temp.como(LL);
    R := R || pg_temp.r2(17, 'Lista: Operación ve vigente, programada y revocada; un líder no (42501)', array[
      case when (select count(*) from jsonb_array_elements(j) e where e->>'estado' in ('revocada', 'programada', 'vigente')) = 3 then null else 'lista: ' || j::text end,
      pg_temp.deniega('select public.sustituciones_lista()', '42501', 'Solo Operación')]);

    -- 18. Tabla cerrada al navegador
    perform pg_temp.como(OP);
    R := R || pg_temp.r2(18, 'Tabla sustituciones cerrada al navegador, también para Operación (42501)', array[
      pg_temp.deniega('select count(*) from public.sustituciones', '42501', 'permission denied'),
      pg_temp.deniega(format('update public.sustituciones set hasta = now() + interval %L where id = %L', '9 days', s2), '42501', 'permission denied')]);

    -- 19. Queda registrado quién nombró y quién revocó
    perform pg_temp.yo();
    R := R || pg_temp.r(19, 'Eventos de nombrar y revocar',
      exists (select 1 from public.eventos where quien::text = OP and que like 'sustituto de Limpieza: PM Beto%')
      and exists (select 1 from public.eventos where quien::text = OP and que like 'sustitución revocada: Limpieza%'));

    -- 20. Operación sigue consultando (Seguimiento)
    perform pg_temp.como(OP);
    R := R || pg_temp.r(20, 'Operación sigue leyendo limpiezas (Seguimiento)', (select count(*) from public.limpiezas where id = l1) = 1);

    -- 21. Avisos: el sustituto vigente recibe los avisos del líder de su departamento
    perform pg_temp.yo();
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, creado_por, es_prueba)
    select l1, propiedad_id, zona, fecha, 'otro', 'Grifo roto', 1, CA::uuid, true from public.limpiezas where id = l1 returning id into po;
    perform pg_temp.como(OP);
    s1 := public.nombrar_sustituto('Limpieza', CB::uuid, now() - interval '1 minute', now() + interval '1 hour', 'Otra vez');
    perform pg_temp.yo();
    select array_to_string(array_agg(a.perfil_id::text order by a.perfil_id), ',') into x from public.avisos_para('pendiente', po) a;
    R := R || pg_temp.r(21, 'Aviso al líder de limpieza también llega a su sustituto (y no a otro cleaner)',
      x like '%' || LL || '%' and x like '%' || CB || '%' and x not like '%' || CA || '%', coalesce(x, '-'));

    -- 22. Un sustituto nunca cambia su nivel guardado
    R := R || pg_temp.r(22, 'El nivel guardado del sustituto no cambia',
      (select nivel::text from public.perfiles where id = CB::uuid) = 'operador' and (select nivel::text from public.perfiles where id = D2::uuid) = 'operador');

    raise exception 'FIN_DE_LAS_PRUEBAS';   -- deshace todo lo de arriba
  exception when others then
    if sqlerrm <> 'FIN_DE_LAS_PRUEBAS' then
      R := R || pg_temp.r(0, 'Error inesperado: las pruebas se cortaron', false, sqlstate || ': ' || sqlerrm);
    end if;
  end;
  perform set_config('role', 'none', true);
  insert into resultados select (e->>'n')::int, e->>'prueba', e->>'resultado' from jsonb_array_elements(R) e;
end $$;

-- 23. Comprobación final: no ha quedado NADA de la prueba
insert into resultados select 23, 'No queda nada de la prueba (usuarios, propiedad, sustituciones, eventos)',
  case when not exists (select 1 from auth.users where id::text like '00000000-0000-0000-0000-0000000034%')
        and not exists (select 1 from public.propiedades where codigo = 'TEST-PM1')
        and not exists (select 1 from public.sustituciones where motivo in ('Vacaciones de la líder', 'Líder de baja', 'Vacaciones', 'Otra vez'))
        and not exists (select 1 from public.eventos where que like 'sustituto de %: PM %')
       then 'OK' else 'FALLO quedan datos de la prueba' end;

select * from resultados order by n;
