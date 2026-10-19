-- OpsFlow · 00 · MONTAR UN PROYECTO SUPABASE DE PRUEBAS (vacío) con el backend actual (scripts 1–33)
-- SOLO en un proyecto NUEVO y VACÍO. NUNCA en producción.
-- Generado a partir de 001_cuentas.sql + supabase/actual/*.sql (sin los archivos de pruebas) con dos cambios:
--   · NO incluye 19-PEGAR-programar_borrado_fotos.sql (tarea nocturna que llama a la función de PRODUCCIÓN)
--   · De 23-PEGAR-trafico.sql NO incluye el apartado 5 (tarea cada 10 min que llama a la función de PRODUCCIÓN)
-- Va en transacciones: si algo falla, borra el proyecto de pruebas y créalo de nuevo (no afecta a producción).

begin;

-- Freno: si ya existe OpsFlow en esta base de datos, parar (puede ser PRODUCCIÓN)
do $$
begin
  if to_regclass('public.perfiles') is not null or to_regclass('public.limpiezas') is not null then
    raise exception 'PARADO: esta base de datos ya tiene OpsFlow (¿es producción?). Usa un proyecto NUEVO y vacío.';
  end if;
end $$;

-- ═══════════════ 001_cuentas.sql ═══════════════
-- OpsFlow · modulo cuentas · 001
-- Tabla de perfiles y reglas de acceso (RLS).
-- Se ejecuta UNA vez en Supabase → SQL Editor → pegar todo → Run.

-- 1. Tipos ---------------------------------------------------------------
create type public.nivel as enum ('operador', 'lider', 'operacion');
create type public.zona  as enum ('Norte', 'Centro', 'Sur');

-- 2. Tabla ---------------------------------------------------------------
create table public.perfiles (
  id                 uuid primary key references auth.users(id),
  nombre             text not null,
  departamento       text not null check (departamento in ('Limpieza', 'Linens', 'Drivers', 'Operación')),
  nivel              public.nivel not null default 'operador',
  zona               public.zona,                       -- null = todas
  idioma             text not null default 'en' check (idioma in ('en', 'es')),
  activo             boolean not null default true,
  debe_cambiar_clave boolean not null default true,
  creado_por         uuid references public.perfiles(id),
  creado_en          timestamptz not null default now(),
  desactivado_en     timestamptz
);

alter table public.perfiles enable row level security;

-- Desde el navegador solo se puede LEER. Crear, cambiar o desactivar
-- se hace unicamente desde las funciones del servidor.
revoke insert, update, delete, truncate on public.perfiles from anon, authenticated;
revoke all on public.perfiles from anon;

-- 3. Ayudantes (leen el perfil de quien esta conectado) ------------------
create or replace function public.mi_nivel()
returns public.nivel
language sql stable security definer set search_path = ''
as $$
  select nivel from public.perfiles where id = (select auth.uid()) and activo
$$;

create or replace function public.mi_departamento()
returns text
language sql stable security definer set search_path = ''
as $$
  select departamento from public.perfiles where id = (select auth.uid()) and activo
$$;

revoke execute on function public.mi_nivel(), public.mi_departamento() from public, anon;
grant  execute on function public.mi_nivel(), public.mi_departamento() to authenticated;

-- 4. Regla de lectura ----------------------------------------------------
--   operador  → solo su perfil
--   lider     → su departamento
--   operacion → todos
create policy "perfiles: lectura por nivel"
on public.perfiles for select to authenticated
using (
  id = (select auth.uid())
  or ((select public.mi_nivel()) = 'lider' and departamento = (select public.mi_departamento()))
  or (select public.mi_nivel()) = 'operacion'
);

-- 5. Unica escritura permitida desde la app: marcar que ya cambie mi clave
create or replace function public.clave_cambiada()
returns void
language sql security definer set search_path = ''
as $$
  update public.perfiles set debe_cambiar_clave = false where id = (select auth.uid())
$$;

revoke execute on function public.clave_cambiada() from public, anon;
grant  execute on function public.clave_cambiada() to authenticated;


-- ═══════════════ 01-PEGAR-002_datos_piloto.sql ═══════════════
-- OpsFlow · modulo datos-piloto · 002
-- Propiedades, checkouts del dia y la funcion que los carga.
-- Se ejecuta UNA vez en Supabase → SQL Editor → pegar todo → Run.

-- 1. Propiedades ---------------------------------------------------------
create table public.propiedades (
  id            uuid primary key default gen_random_uuid(),
  codigo        text not null unique check (codigo = upper(codigo) and length(codigo) between 2 and 30),
  nombre        text not null,
  zona          public.zona not null,
  pueblo        text not null,
  direccion     text,
  mapa_url      text,
  camas_dobles  int not null default 0 check (camas_dobles between 0 and 10),
  camas_indiv   int not null default 0 check (camas_indiv between 0 and 10),
  sofas_cama    int not null default 0 check (sofas_cama between 0 and 5),
  banos         int not null default 1 check (banos between 0 and 10),
  notas         text,
  activa        boolean not null default true,
  es_prueba     boolean not null default false,
  creado_en     timestamptz not null default now()
);
alter table public.propiedades enable row level security;
revoke all on public.propiedades from anon;
revoke delete, truncate on public.propiedades from authenticated;   -- se desactivan, no se borran

create policy "propiedades: leen lideres y operacion"
on public.propiedades for select to authenticated
using ((select public.mi_nivel()) in ('lider', 'operacion'));

create policy "propiedades: crea operacion"
on public.propiedades for insert to authenticated
with check ((select public.mi_nivel()) = 'operacion');

create policy "propiedades: edita operacion"
on public.propiedades for update to authenticated
using ((select public.mi_nivel()) = 'operacion')
with check ((select public.mi_nivel()) = 'operacion');

-- 2. Checkouts -----------------------------------------------------------
create table public.checkouts (
  id            uuid primary key default gen_random_uuid(),
  propiedad_id  uuid not null references public.propiedades(id),
  fecha         date not null,
  hora_salida   time not null,
  hora_entrada  time,
  prioritario   boolean generated always as (hora_entrada is not null) stored,
  es_prueba     boolean not null default false,
  origen        text not null default 'manual' check (origen in ('manual', 'hostaway')),
  reserva_id    text,
  cargado_por   uuid references public.perfiles(id),
  cargado_en    timestamptz not null default now(),
  unique (propiedad_id, fecha)
);
create index checkouts_fecha on public.checkouts (fecha);
alter table public.checkouts enable row level security;
revoke all on public.checkouts from anon;
-- Nadie escribe directamente: solo a traves de cargar_checkouts(), que valida todo.
revoke insert, update, delete, truncate on public.checkouts from authenticated;

create policy "checkouts: leen lideres y operacion"
on public.checkouts for select to authenticated
using ((select public.mi_nivel()) in ('lider', 'operacion'));

-- 3. Cargar checkouts ----------------------------------------------------
-- Una linea por checkout:  CODIGO HH:MM            (solo salida)
--                          CODIGO HH:MM HH:MM      (salida y entrada el mismo dia)
-- p_confirmar = false → solo revisa y devuelve el resumen, NO guarda nada.
-- p_confirmar = true  → guarda las lineas buenas; las rechazadas se ignoran.
create or replace function public.cargar_checkouts(p_fecha date, p_texto text, p_confirmar boolean default false)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_nivel public.nivel := public.mi_nivel();
  v_dep   text := public.mi_departamento();
  v_linea text; v_n int := 0; v_m text[];
  v_codigo text; v_sal time; v_ent time;
  v_prop  record;
  v_vistos text[] := '{}';
  v_cargados jsonb := '[]'; v_actualizados jsonb := '[]'; v_rechazados jsonb := '[]';
  v_buenas jsonb := '[]';
  v_b jsonb;
begin
  if not (v_nivel = 'operacion' or (v_nivel = 'lider' and v_dep = 'Limpieza')) then
    raise exception 'Solo Operación o el líder de limpieza pueden cargar checkouts.';
  end if;
  if p_fecha is null then raise exception 'Falta la fecha.'; end if;

  foreach v_linea in array regexp_split_to_array(coalesce(p_texto, ''), E'\\r?\\n') loop
    v_n := v_n + 1;
    v_linea := btrim(v_linea);
    continue when v_linea = '';

    v_m := regexp_match(v_linea, '^(\S+)\s+(\d{1,2})[:.](\d{2})(?:\s+(\d{1,2})[:.](\d{2}))?$');
    if v_m is null then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'Formato: CÓDIGO HH:MM o CÓDIGO HH:MM HH:MM');
      continue;
    end if;

    v_codigo := upper(v_m[1]);
    if v_m[2]::int > 23 or v_m[3]::int > 59 or (v_m[4] is not null and (v_m[4]::int > 23 or v_m[5]::int > 59)) then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'Hora no válida');
      continue;
    end if;
    v_sal := make_time(v_m[2]::int, v_m[3]::int, 0);
    v_ent := case when v_m[4] is null then null else make_time(v_m[4]::int, v_m[5]::int, 0) end;
    if v_ent is not null and v_ent < v_sal then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'La entrada es antes que la salida');
      continue;
    end if;

    if v_codigo = any(v_vistos) then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'Código repetido en esta carga');
      continue;
    end if;

    select id, codigo, es_prueba, activa into v_prop from public.propiedades where codigo = v_codigo;
    if not found then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'Ese código no existe');
      continue;
    end if;
    if not v_prop.activa then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'Propiedad desactivada');
      continue;
    end if;

    v_vistos := v_vistos || v_codigo;
    v_b := jsonb_build_object('codigo', v_codigo, 'salida', to_char(v_sal, 'HH24:MI'),
                              'entrada', to_char(v_ent, 'HH24:MI'));
    if exists (select 1 from public.checkouts where propiedad_id = v_prop.id and fecha = p_fecha) then
      v_actualizados := v_actualizados || v_b;
    else
      v_cargados := v_cargados || v_b;
    end if;
    v_buenas := v_buenas || (v_b || jsonb_build_object('pid', v_prop.id, 'prueba', v_prop.es_prueba));
  end loop;

  if p_confirmar then
    insert into public.checkouts (propiedad_id, fecha, hora_salida, hora_entrada, es_prueba, cargado_por)
    select (x->>'pid')::uuid, p_fecha, (x->>'salida')::time, nullif(x->>'entrada', '')::time,
           (x->>'prueba')::boolean, (select auth.uid())
    from jsonb_array_elements(v_buenas) x
    on conflict (propiedad_id, fecha) do update
      set hora_salida = excluded.hora_salida, hora_entrada = excluded.hora_entrada,
          cargado_por = excluded.cargado_por, cargado_en = now();
  end if;

  return jsonb_build_object('guardado', p_confirmar and jsonb_array_length(v_buenas) > 0,
                            'cargados', v_cargados, 'actualizados', v_actualizados, 'rechazados', v_rechazados);
end $$;

revoke execute on function public.cargar_checkouts(date, text, boolean) from public, anon;
grant  execute on function public.cargar_checkouts(date, text, boolean) to authenticated;


-- ═══════════════ 02-PEGAR-003_datos_prueba.sql ═══════════════
-- OpsFlow · modulo datos-piloto · 003
-- 20 propiedades FICTICIAS (TEST-N01 … TEST-N20) y las funciones del modo prueba.
-- Se puede ejecutar mas de una vez: no duplica nada.

insert into public.propiedades (codigo, nombre, zona, pueblo, direccion, camas_dobles, camas_indiv, sofas_cama, banos, es_prueba) values
  ('TEST-N01', 'TEST · Bay View Studio',        'Norte', 'Mellieħa',      'Triq il-Prova 1, Mellieħa',      1, 0, 0, 1, true),
  ('TEST-N02', 'TEST · Sunset Terrace 2BR',     'Norte', 'Mellieħa',      'Triq il-Prova 2, Mellieħa',      2, 0, 1, 2, true),
  ('TEST-N03', 'TEST · Harbour Loft',           'Norte', 'Mellieħa',      'Triq il-Prova 3, Mellieħa',      1, 1, 0, 1, true),
  ('TEST-N04', 'TEST · Family Penthouse',       'Norte', 'St Paul''s Bay', 'Triq il-Prova 4, St Paul''s Bay', 2, 2, 0, 2, true),
  ('TEST-N05', 'TEST · Seafront 1BR',           'Norte', 'St Paul''s Bay', 'Triq il-Prova 5, St Paul''s Bay', 1, 0, 1, 1, true),
  ('TEST-N06', 'TEST · Garden Maisonette',      'Norte', 'St Paul''s Bay', 'Triq il-Prova 6, St Paul''s Bay', 2, 1, 0, 1, true),
  ('TEST-N07', 'TEST · Promenade Apartment',    'Norte', 'Qawra',         'Triq il-Prova 7, Qawra',         2, 0, 0, 1, true),
  ('TEST-N08', 'TEST · Pool Residence 3BR',     'Norte', 'Qawra',         'Triq il-Prova 8, Qawra',         3, 0, 1, 2, true),
  ('TEST-N09', 'TEST · Compact Studio',         'Norte', 'Qawra',         'Triq il-Prova 9, Qawra',         1, 0, 0, 1, true),
  ('TEST-N10', 'TEST · Corner Flat',            'Norte', 'Qawra',         'Triq il-Prova 10, Qawra',        1, 2, 0, 1, true),
  ('TEST-N11', 'TEST · Square View 2BR',        'Norte', 'Buġibba',       'Triq il-Prova 11, Buġibba',      2, 0, 0, 1, true),
  ('TEST-N12', 'TEST · Rooftop Duplex',         'Norte', 'Buġibba',       'Triq il-Prova 12, Buġibba',      2, 1, 1, 2, true),
  ('TEST-N13', 'TEST · Budget Twin',            'Norte', 'Buġibba',       'Triq il-Prova 13, Buġibba',      0, 2, 0, 1, true),
  ('TEST-N14', 'TEST · Marina Suite',           'Norte', 'Buġibba',       'Triq il-Prova 14, Buġibba',      1, 0, 1, 1, true),
  ('TEST-N15', 'TEST · Ridge House',            'Norte', 'Xemxija',       'Triq il-Prova 15, Xemxija',      3, 1, 0, 2, true),
  ('TEST-N16', 'TEST · Valley Apartment',       'Norte', 'Xemxija',       'Triq il-Prova 16, Xemxija',      2, 0, 0, 1, true),
  ('TEST-N17', 'TEST · Quiet 1BR',              'Norte', 'Xemxija',       'Triq il-Prova 17, Xemxija',      1, 0, 0, 1, true),
  ('TEST-N18', 'TEST · Farmhouse',              'Norte', 'Mġarr',         'Triq il-Prova 18, Mġarr',        3, 2, 0, 3, true),
  ('TEST-N19', 'TEST · Village Flat',           'Norte', 'Mġarr',         'Triq il-Prova 19, Mġarr',        1, 1, 0, 1, true),
  ('TEST-N20', 'TEST · Countryside 2BR',        'Norte', 'Mġarr',         'Triq il-Prova 20, Mġarr',        2, 0, 1, 1, true)
on conflict (codigo) do nothing;

-- Genera entre 8 y 14 checkouts al azar sobre propiedades TEST, un tercio con entrada el mismo dia.
create or replace function public.generar_dia_prueba(p_fecha date)
returns int
language plpgsql security definer set search_path = ''
as $$
declare v_n int;
begin
  if public.mi_nivel() is distinct from 'operacion' then
    raise exception 'Solo Operación puede generar días de prueba.';
  end if;
  v_n := 8 + floor(random() * 7)::int;
  insert into public.checkouts (propiedad_id, fecha, hora_salida, hora_entrada, es_prueba, cargado_por)
  select p.id, p_fecha,
         make_time(9 + floor(random() * 3)::int, (floor(random() * 2) * 30)::int, 0),
         case when random() < 0.34 then make_time(15 + floor(random() * 2)::int, 0, 0) end,
         true, (select auth.uid())
  from (select id from public.propiedades where es_prueba and activa order by random() limit v_n) p
  on conflict (propiedad_id, fecha) do update
    set hora_salida = excluded.hora_salida, hora_entrada = excluded.hora_entrada, cargado_en = now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Borra TODO lo marcado como prueba. Nunca toca datos reales.
create or replace function public.borrar_datos_prueba()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_c int; v_p int;
begin
  if public.mi_nivel() is distinct from 'operacion' then
    raise exception 'Solo Operación puede borrar los datos de prueba.';
  end if;
  delete from public.checkouts
   where es_prueba or propiedad_id in (select id from public.propiedades where es_prueba);
  get diagnostics v_c = row_count;
  delete from public.propiedades where es_prueba;
  get diagnostics v_p = row_count;
  return jsonb_build_object('checkouts', v_c, 'propiedades', v_p);
end $$;

revoke execute on function public.generar_dia_prueba(date), public.borrar_datos_prueba() from public, anon;
grant  execute on function public.generar_dia_prueba(date), public.borrar_datos_prueba() to authenticated;


-- ═══════════════ 04-PEGAR-004_cadena.sql ═══════════════
-- OpsFlow · modulo cadena-checkout · 004
-- Limpiezas (una por checkout, automaticas), pendientes, registro de eventos
-- y las funciones de cada boton. Se ejecuta UNA vez: SQL Editor → pegar todo → Run.

-- 1. Tipos ---------------------------------------------------------------
create type public.estado_limpieza  as enum ('sin_asignar', 'asignada', 'en_curso', 'terminada', 'no_pude_entrar');
create type public.tipo_limpieza    as enum ('normal', 'refresh', 'deep', 'huesped_dentro', 'foto', 'post_mantenimiento');
create type public.tipo_pendiente   as enum ('linens', 'recogida', 'otro');
create type public.estado_pendiente as enum ('abierto', 'preparado', 'entregado', 'cerrado');

-- 2. Tablas --------------------------------------------------------------
create table public.limpiezas (
  id            uuid primary key default gen_random_uuid(),
  checkout_id   uuid not null unique references public.checkouts(id) on delete cascade,
  propiedad_id  uuid not null references public.propiedades(id),
  zona          public.zona not null,
  fecha         date not null,
  tipo          public.tipo_limpieza not null default 'normal',
  estado        public.estado_limpieza not null default 'sin_asignar',
  asignada_a    uuid references public.perfiles(id),
  orden         int check (orden between 1 and 50),
  publicada     boolean not null default false,
  inicio        timestamptz,
  fin           timestamptz,
  motivo_no_entrar text,
  es_prueba     boolean not null default false,
  creado_en     timestamptz not null default now()
);
create index limpiezas_fecha on public.limpiezas (fecha);

create table public.pendientes (
  id            uuid primary key default gen_random_uuid(),
  limpieza_id   uuid not null references public.limpiezas(id) on delete cascade,
  propiedad_id  uuid not null references public.propiedades(id),
  zona          public.zona not null,
  fecha         date not null,
  tipo          public.tipo_pendiente not null,
  detalle       text not null check (length(detalle) between 1 and 200),
  cantidad      int not null default 1 check (cantidad between 1 and 50),
  prioritario   boolean not null default false,
  estado        public.estado_pendiente not null default 'abierto',
  creado_por    uuid, creado_en    timestamptz not null default now(),
  preparado_por uuid, preparado_en timestamptz,
  entregado_por uuid, entregado_en timestamptz,
  cerrado_por   uuid, cerrado_en   timestamptz,
  es_prueba     boolean not null default false
);
create index pendientes_fecha on public.pendientes (fecha);

create table public.eventos (
  id            bigint generated always as identity primary key,
  cuando        timestamptz not null default now(),
  quien         uuid,
  que           text not null,
  limpieza_id   uuid references public.limpiezas(id) on delete cascade,
  pendiente_id  uuid references public.pendientes(id) on delete cascade
);

-- Nadie escribe estas tablas directamente: solo las funciones de abajo.
alter table public.limpiezas  enable row level security;
alter table public.pendientes enable row level security;
alter table public.eventos    enable row level security;
revoke all on public.limpiezas, public.pendientes, public.eventos from anon;
revoke insert, update, delete, truncate on public.limpiezas, public.pendientes, public.eventos from authenticated;

-- 3. Ayudante: zona de quien esta conectado -------------------------------
create or replace function public.mi_zona()
returns public.zona language sql stable security definer set search_path = ''
as $$ select zona from public.perfiles where id = (select auth.uid()) and activo $$;
revoke execute on function public.mi_zona() from public, anon;
grant  execute on function public.mi_zona() to authenticated;

-- 4. Quien ve que ---------------------------------------------------------
create policy "limpiezas: lectura por rol" on public.limpiezas for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) in ('Limpieza', 'Drivers'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and publicada and asignada_a = (select auth.uid()))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and publicada and zona = (select public.mi_zona()))
);

create policy "pendientes: lectura por rol" on public.pendientes for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Linens' and tipo = 'linens')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Drivers' and tipo in ('linens', 'recogida'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and limpieza_id in (select id from public.limpiezas where asignada_a = (select auth.uid())))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and zona = (select public.mi_zona())
       and (tipo = 'recogida' or (tipo = 'linens' and estado <> 'abierto')))
);

create policy "eventos: solo operacion" on public.eventos for select to authenticated
using ((select public.mi_nivel()) = 'operacion');

-- 5. Cada checkout crea su limpieza ---------------------------------------
create or replace function public.crear_limpieza_de_checkout()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.limpiezas (checkout_id, propiedad_id, zona, fecha, es_prueba)
  select new.id, new.propiedad_id, p.zona, new.fecha, new.es_prueba
  from public.propiedades p where p.id = new.propiedad_id
  on conflict (checkout_id) do nothing;
  return new;
end $$;

create trigger checkout_crea_limpieza
after insert on public.checkouts
for each row execute function public.crear_limpieza_de_checkout();

-- Los checkouts que ya estaban cargados tambien reciben su limpieza
insert into public.limpiezas (checkout_id, propiedad_id, zona, fecha, es_prueba)
select c.id, c.propiedad_id, p.zona, c.fecha, c.es_prueba
from public.checkouts c join public.propiedades p on p.id = c.propiedad_id
on conflict (checkout_id) do nothing;

-- 6. Funciones de los botones ---------------------------------------------
-- Todas: comprueban quien llama y que el paso es valido, y dejan un evento.

create or replace function public._evento(p_que text, p_limpieza uuid, p_pendiente uuid)
returns void language sql security definer set search_path = ''
as $$ insert into public.eventos (quien, que, limpieza_id, pendiente_id) values ((select auth.uid()), p_que, p_limpieza, p_pendiente) $$;
revoke execute on function public._evento(text, uuid, uuid) from public, anon, authenticated;

create or replace function public._lider_limpieza()
returns boolean language sql stable security definer set search_path = ''
as $$ select public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Limpieza') $$;
revoke execute on function public._lider_limpieza() from public, anon, authenticated;

-- Asignar cleaner, orden y tipo (lider de limpieza u Operacion)
create or replace function public.asignar_limpieza(p_id uuid, p_cleaner uuid, p_orden int, p_tipo public.tipo_limpieza)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación asignan limpiezas.'; end if;
  select * into v from public.limpiezas where id = p_id for update;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if v.estado not in ('sin_asignar', 'asignada') then raise exception 'Esa limpieza ya empezó: no se puede reasignar.'; end if;
  if p_cleaner is not null and not exists (
       select 1 from public.perfiles where id = p_cleaner and activo and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception 'Solo se puede asignar a un cleaner activo.';
  end if;
  update public.limpiezas
     set asignada_a = p_cleaner, orden = p_orden, tipo = coalesce(p_tipo, tipo),
         estado = case when p_cleaner is null then 'sin_asignar' else 'asignada' end::public.estado_limpieza,
         publicada = case when p_cleaner is null then false else publicada end
   where id = p_id;
  perform public._evento('asignada', p_id, null);
end $$;

-- Publicar el orden del dia: el cleaner solo ve lo publicado
create or replace function public.publicar_orden(p_fecha date)
returns int language plpgsql security definer set search_path = ''
as $$
declare n int;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación publican el orden.'; end if;
  update public.limpiezas set publicada = true
   where fecha = p_fecha and asignada_a is not null and not publicada;
  get diagnostics n = row_count;
  insert into public.eventos (quien, que) values ((select auth.uid()), 'orden publicado ' || p_fecha || ' (' || n || ')');
  return n;
end $$;

-- Cleaner: empezar, terminar, no pude entrar
create or replace function public._mi_limpieza(p_id uuid)
returns public.limpiezas language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id for update;
  if not found or v.asignada_a is distinct from (select auth.uid()) or not v.publicada
     or public.mi_nivel() is null then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return v;
end $$;
revoke execute on function public._mi_limpieza(uuid) from public, anon, authenticated;

create or replace function public.iniciar_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'asignada' then raise exception 'Solo se puede empezar una limpieza asignada.'; end if;
  update public.limpiezas set estado = 'en_curso', inicio = now() where id = p_id;
  perform public._evento('limpieza iniciada', p_id, null);
end $$;

create or replace function public.terminar_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  update public.limpiezas set estado = 'terminada', fin = now() where id = p_id;
  perform public._evento('limpieza terminada', p_id, null);
end $$;

create or replace function public.no_pude_entrar(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado not in ('asignada', 'en_curso') then raise exception 'Esta limpieza ya está cerrada.'; end if;
  if coalesce(btrim(p_motivo), '') = '' then raise exception 'Falta el motivo.'; end if;
  update public.limpiezas set estado = 'no_pude_entrar', motivo_no_entrar = left(btrim(p_motivo), 200), fin = now() where id = p_id;
  perform public._evento('no pude entrar: ' || left(btrim(p_motivo), 200), p_id, null);
end $$;

-- Cleaner (o lider de limpieza): reportar un pendiente
create or replace function public.reportar_pendiente(p_limpieza uuid, p_tipo public.tipo_pendiente, p_detalle text, p_cantidad int default 1)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_prio boolean; v_id uuid;
begin
  select * into v from public.limpiezas where id = p_limpieza;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if not public._lider_limpieza() and (v.asignada_a is distinct from (select auth.uid()) or not v.publicada) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  if v.estado not in ('en_curso', 'terminada') then raise exception 'Primero hay que empezar la limpieza.'; end if;
  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba)
  values (v.id, v.propiedad_id, v.zona, v.fecha, p_tipo,
          coalesce(nullif(btrim(p_detalle), ''), case when p_tipo = 'recogida' then 'Basura y linens sucios' end),
          coalesce(p_cantidad, 1), coalesce(v_prio, false), (select auth.uid()), v.es_prueba)
  returning id into v_id;
  perform public._evento('pendiente reportado (' || p_tipo || ')', v.id, v_id);
  return v_id;
end $$;

-- Lider de linens: preparado
create or replace function public.marcar_preparado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Linens')) then
    raise exception 'Solo linens u Operación marcan preparado.';
  end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or v.tipo <> 'linens' then raise exception 'Ese pendiente no es de linens.'; end if;
  if v.estado <> 'abierto' then raise exception 'Ese pendiente ya está preparado.'; end if;
  update public.pendientes set estado = 'preparado', preparado_por = (select auth.uid()), preparado_en = now() where id = p_id;
  perform public._evento('preparado por linens', v.limpieza_id, p_id);
end $$;

-- Driver: entregado (linens) o recogido (recogida)
create or replace function public.marcar_entregado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and public.mi_zona() = v.zona)) then
    raise exception 'Solo el driver de la zona puede marcar la entrega.';
  end if;
  if v.tipo = 'linens' and v.estado = 'preparado' then
    update public.pendientes set estado = 'entregado', entregado_por = (select auth.uid()), entregado_en = now() where id = p_id;
    perform public._evento('entregado por driver', v.limpieza_id, p_id);
  elsif v.tipo = 'recogida' and v.estado = 'abierto' then
    update public.pendientes set estado = 'cerrado', entregado_por = (select auth.uid()), entregado_en = now(),
                                 cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
    perform public._evento('recogido por driver', v.limpieza_id, p_id);
  else
    raise exception 'Ese pendiente todavía no está listo para el driver.';
  end if;
end $$;

-- Cleaner: recibido → cerrado (decision: solo el cleaner cierra)
create or replace function public.marcar_recibido(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes; v_dueno uuid;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  select asignada_a into v_dueno from public.limpiezas where id = v.limpieza_id;
  if v_dueno is distinct from (select auth.uid()) or public.mi_nivel() is null then
    raise exception 'Solo el cleaner de esta limpieza puede marcar recibido.';
  end if;
  if v.tipo <> 'linens' or v.estado <> 'entregado' then raise exception 'Todavía no se ha entregado.'; end if;
  update public.pendientes set estado = 'cerrado', cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
  perform public._evento('recibido por cleaner: cerrado', v.limpieza_id, p_id);
end $$;

-- Lider de limpieza u Operacion: resolver un pendiente de tipo "otro"
create or replace function public.resolver_pendiente(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación lo resuelven.'; end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or v.tipo <> 'otro' or v.estado <> 'abierto' then raise exception 'Ese pendiente no se puede resolver así.'; end if;
  update public.pendientes set estado = 'cerrado', cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
  perform public._evento('resuelto por líder', v.limpieza_id, p_id);
end $$;

-- 7. Pantallas del campo (devuelven todo lo que necesita el telefono) ------
create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden, 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar,
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and l.asignada_a = (select auth.uid())
      and public.mi_nivel() is not null
  ) t
$$;

create or replace function public.mi_ruta(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_zona public.zona := public.mi_zona();
begin
  if not (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers') then
    raise exception 'Esta pantalla es para drivers.';
  end if;
  return jsonb_build_object(
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'estado', pe.estado,
        'prioritario', pe.prioritario, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by pe.prioritario desc, pe.creado_en)
      from public.pendientes pe
      join public.limpiezas l on l.id = pe.limpieza_id
      join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.fecha = p_fecha and pe.zona = v_zona
        and ((pe.tipo = 'linens' and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto'))), '[]'::jsonb),
    'orden', coalesce((select jsonb_agg(jsonb_build_object(
        'cleaner', pf.nombre, 'orden', l.orden, 'estado', l.estado, 'codigo', p.codigo, 'nombre', p.nombre,
        'pueblo', p.pueblo, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by pf.nombre, l.orden)
      from public.limpiezas l
      join public.propiedades p on p.id = l.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      join public.perfiles pf on pf.id = l.asignada_a
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada), '[]'::jsonb));
end $$;

-- 8. Tablero de Operacion -------------------------------------------------
create or replace function public.tablero(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'El tablero es de Operación.'; end if;
  return jsonb_build_object(
    'limpiezas', (select coalesce(jsonb_object_agg(estado, n), '{}'::jsonb)
                  from (select estado, count(*) n from public.limpiezas where fecha = p_fecha group by estado) a),
    'sin_publicar', (select count(*) from public.limpiezas where fecha = p_fecha and asignada_a is not null and not publicada),
    'en_linens',   (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'linens' and estado = 'abierto'),
    'en_driver',   (select count(*) from public.pendientes where fecha = p_fecha and ((tipo = 'linens' and estado = 'preparado') or (tipo = 'recogida' and estado = 'abierto'))),
    'por_recibir', (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'linens' and estado = 'entregado'),
    'otros_abiertos', (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'otro' and estado = 'abierto'),
    'cerrados',    (select count(*) from public.pendientes where fecha = p_fecha and estado = 'cerrado'),
    'minutos_cierre', (select round(avg(extract(epoch from cerrado_en - creado_en)) / 60)
                       from public.pendientes where fecha = p_fecha and estado = 'cerrado'),
    'no_pude_entrar', (select coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'nombre', p.nombre, 'motivo', l.motivo_no_entrar)), '[]'::jsonb)
                       from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
                       where l.fecha = p_fecha and l.estado = 'no_pude_entrar'));
end $$;

-- 9. Permisos de las funciones --------------------------------------------
revoke execute on function
  public.crear_limpieza_de_checkout(),
  public.asignar_limpieza(uuid, uuid, int, public.tipo_limpieza), public.publicar_orden(date),
  public.iniciar_limpieza(uuid), public.terminar_limpieza(uuid), public.no_pude_entrar(uuid, text),
  public.reportar_pendiente(uuid, public.tipo_pendiente, text, int),
  public.marcar_preparado(uuid), public.marcar_entregado(uuid), public.marcar_recibido(uuid), public.resolver_pendiente(uuid),
  public.mi_dia(date), public.mi_ruta(date), public.tablero(date)
from public, anon;
grant execute on function
  public.asignar_limpieza(uuid, uuid, int, public.tipo_limpieza), public.publicar_orden(date),
  public.iniciar_limpieza(uuid), public.terminar_limpieza(uuid), public.no_pude_entrar(uuid, text),
  public.reportar_pendiente(uuid, public.tipo_pendiente, text, int),
  public.marcar_preparado(uuid), public.marcar_entregado(uuid), public.marcar_recibido(uuid), public.resolver_pendiente(uuid),
  public.mi_dia(date), public.mi_ruta(date), public.tablero(date)
to authenticated;


-- ═══════════════ 06-PEGAR-006_avisos.sql ═══════════════
-- OpsFlow · modulo avisos · 006
-- Suscripciones de los telefonos y calculo de quien recibe cada aviso.
-- Se ejecuta UNA vez: SQL Editor → pegar todo → Run.

-- 1. Tablas --------------------------------------------------------------
create table public.suscripciones (
  id           uuid primary key default gen_random_uuid(),
  perfil_id    uuid not null references public.perfiles(id) on delete cascade,
  endpoint     text not null unique check (endpoint like 'https://%' and length(endpoint) < 1000),
  p256dh       text not null check (length(p256dh) between 20 and 200),
  auth         text not null check (length(auth) between 10 and 100),
  dispositivo  text check (length(dispositivo) <= 120),
  creado_en    timestamptz not null default now(),
  ultimo_ok    timestamptz
);
create index suscripciones_perfil on public.suscripciones (perfil_id);

create table public.avisos_enviados (
  id           bigint generated always as identity primary key,
  clave        text not null unique,          -- que paso + a quien: evita mandar dos veces lo mismo
  perfil_id    uuid references public.perfiles(id) on delete set null,
  titulo       text not null,
  enviado_en   timestamptz not null default now(),
  resultado    text
);

-- Nadie las lee ni las escribe desde la app: solo las funciones de abajo y el servidor.
alter table public.suscripciones   enable row level security;
alter table public.avisos_enviados enable row level security;
revoke all on public.suscripciones, public.avisos_enviados from anon, authenticated;

-- 2. Funciones para la app -----------------------------------------------
-- Guardar el telefono de quien esta conectado (si el telefono era de otra cuenta, pasa a esta)
create or replace function public.guardar_suscripcion(p_endpoint text, p_p256dh text, p_auth text, p_dispositivo text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is null then raise exception 'Cuenta no activa.'; end if;
  insert into public.suscripciones (perfil_id, endpoint, p256dh, auth, dispositivo)
  values ((select auth.uid()), p_endpoint, p_p256dh, p_auth, left(p_dispositivo, 120))
  on conflict (endpoint) do update
     set perfil_id = excluded.perfil_id, p256dh = excluded.p256dh, auth = excluded.auth,
         dispositivo = excluded.dispositivo, creado_en = now();
end $$;

-- Quitar un telefono: solo si es tuyo
create or replace function public.borrar_suscripcion(p_endpoint text)
returns void language sql security definer set search_path = ''
as $$ delete from public.suscripciones where endpoint = p_endpoint and perfil_id = (select auth.uid()) $$;

-- Cuantos telefonos tengo con avisos (para el boton)
create or replace function public.mis_avisos()
returns int language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.suscripciones where perfil_id = (select auth.uid()) and public.mi_nivel() is not null $$;

revoke execute on function public.guardar_suscripcion(text, text, text, text), public.borrar_suscripcion(text), public.mis_avisos()
  from public, anon;
grant execute on function public.guardar_suscripcion(text, text, text, text), public.borrar_suscripcion(text), public.mis_avisos()
  to authenticated;

-- 3. Quien recibe cada aviso (solo el servidor) ---------------------------
-- Devuelve una fila por persona NUEVA a avisar, con sus telefonos, y la deja apuntada
-- en avisos_enviados para que el mismo aviso no salga dos veces.
create or replace function public.avisos_para(p_tipo text, p_id uuid default null, p_fecha date default null)
returns table (perfil_id uuid, titulo text, cuerpo text, url text, clave text, telefonos jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  pe public.pendientes; li public.limpiezas; pr public.propiedades; ck public.checkouts;
  v_aviso text; v_ok boolean := true;
begin
  create temp table if not exists _dest (perfil_id uuid, idioma text, t_es text, t_en text, c_es text, c_en text, url text, clave text) on commit drop;
  truncate _dest;

  if p_tipo = 'pendiente' then
    select * into pe from public.pendientes where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = pe.propiedad_id;
    select c.* into ck from public.checkouts c join public.limpiezas l on l.checkout_id = c.id where l.id = pe.limpieza_id;
    v_aviso := 'pendiente:' || pe.id || ':' || pe.estado;

    if pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || pe.cantidad || ' × ' || pe.detalle, 'Linens: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || pe.cantidad || ' × ' || pe.detalle, 'Deliver: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' then
      -- 4. Recogida → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Recoger: basura y linens sucios', 'Pick up: trash & dirty linens',
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'linens' and pe.estado = 'entregado' then
      -- 5. Entregado → el cleaner que lo pidio
      insert into _dest select p.id, p.idioma,
        'Entregado: ' || pe.cantidad || ' × ' || pe.detalle, 'Delivered: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=asignar', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en;
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found or li.estado <> 'no_pude_entrar' then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=asignar' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));

  elsif p_tipo = 'orden' then
    if p_fecha is null then return; end if;
    -- 1. Orden publicado → cada cleaner con limpiezas publicadas ese dia
    --    (la clave lleva cuantas tiene: si el lider le anade otra y publica, le vuelve a sonar)
    insert into _dest select p.id, p.idioma,
      'Orden de limpieza listo', 'Your cleaning order is ready',
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartamento' || case when count(*) > 1 then 's' else '' end,
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartment' || case when count(*) > 1 then 's' else '' end,
      './', 'orden:' || p_fecha || ':' || p.id || ':' || count(*)
    from public.limpiezas l join public.perfiles p on p.id = l.asignada_a
    where l.fecha = p_fecha and l.publicada and p.activo
    group by p.id, p.idioma;

  else
    return;
  end if;

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id);

  -- Apuntar los nuevos; los que ya estaban apuntados no salen otra vez
  return query
  with nuevos as (
    insert into public.avisos_enviados (clave, perfil_id, titulo)
    select d.clave, d.perfil_id, case when d.idioma = 'es' then d.t_es else d.t_en end from _dest d
    on conflict (clave) do nothing
    returning avisos_enviados.clave
  )
  select d.perfil_id,
         case when d.idioma = 'es' then d.t_es else d.t_en end,
         case when d.idioma = 'es' then d.c_es else d.c_en end,
         d.url, d.clave,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                   from public.suscripciones s where s.perfil_id = d.perfil_id), '[]'::jsonb)
  from _dest d join nuevos n on n.clave = d.clave;
end $$;

revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;


-- ═══════════════ 09-PEGAR-arreglo_avisos.sql ═══════════════
-- OpsFlow · arreglo del modulo avisos (9 oct 2026)
-- Supabase bloquea los UPDATE sin WHERE cuando la llamada llega desde la app/funcion (pg-safeupdate).
-- Esto reemplaza la funcion avisos_para con los UPDATE corregidos. Se puede ejecutar varias veces.

-- 3. Quien recibe cada aviso (solo el servidor) ---------------------------
-- Devuelve una fila por persona NUEVA a avisar, con sus telefonos, y la deja apuntada
-- en avisos_enviados para que el mismo aviso no salga dos veces.
create or replace function public.avisos_para(p_tipo text, p_id uuid default null, p_fecha date default null)
returns table (perfil_id uuid, titulo text, cuerpo text, url text, clave text, telefonos jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  pe public.pendientes; li public.limpiezas; pr public.propiedades; ck public.checkouts;
  v_aviso text; v_ok boolean := true;
begin
  create temp table if not exists _dest (perfil_id uuid, idioma text, t_es text, t_en text, c_es text, c_en text, url text, clave text) on commit drop;
  truncate _dest;

  if p_tipo = 'pendiente' then
    select * into pe from public.pendientes where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = pe.propiedad_id;
    select c.* into ck from public.checkouts c join public.limpiezas l on l.checkout_id = c.id where l.id = pe.limpieza_id;
    v_aviso := 'pendiente:' || pe.id || ':' || pe.estado;

    if pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || pe.cantidad || ' × ' || pe.detalle, 'Linens: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || pe.cantidad || ' × ' || pe.detalle, 'Deliver: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' then
      -- 4. Recogida → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Recoger: basura y linens sucios', 'Pick up: trash & dirty linens',
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'linens' and pe.estado = 'entregado' then
      -- 5. Entregado → el cleaner que lo pidio
      insert into _dest select p.id, p.idioma,
        'Entregado: ' || pe.cantidad || ' × ' || pe.detalle, 'Delivered: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=asignar', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en where true;  -- Supabase exige WHERE en todo UPDATE
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found or li.estado <> 'no_pude_entrar' then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=asignar' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));

  elsif p_tipo = 'orden' then
    if p_fecha is null then return; end if;
    -- 1. Orden publicado → cada cleaner con limpiezas publicadas ese dia
    --    (la clave lleva cuantas tiene: si el lider le anade otra y publica, le vuelve a sonar)
    insert into _dest select p.id, p.idioma,
      'Orden de limpieza listo', 'Your cleaning order is ready',
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartamento' || case when count(*) > 1 then 's' else '' end,
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartment' || case when count(*) > 1 then 's' else '' end,
      './', 'orden:' || p_fecha || ':' || p.id || ':' || count(*)
    from public.limpiezas l join public.perfiles p on p.id = l.asignada_a
    where l.fecha = p_fecha and l.publicada and p.activo
    group by p.id, p.idioma;

  else
    return;
  end if;

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id) where true;

  -- Apuntar los nuevos; los que ya estaban apuntados no salen otra vez
  return query
  with nuevos as (
    insert into public.avisos_enviados (clave, perfil_id, titulo)
    select d.clave, d.perfil_id, case when d.idioma = 'es' then d.t_es else d.t_en end from _dest d
    on conflict (clave) do nothing
    returning avisos_enviados.clave
  )
  select d.perfil_id,
         case when d.idioma = 'es' then d.t_es else d.t_en end,
         case when d.idioma = 'es' then d.c_es else d.c_en end,
         d.url, d.clave,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                   from public.suscripciones s where s.perfil_id = d.perfil_id), '[]'::jsonb)
  from _dest d join nuevos n on n.clave = d.clave;
end $$;

revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;


-- ═══════════════ 10-PEGAR-limpieza_guiada.sql ═══════════════
-- OpsFlow · modulo limpieza-guiada · 010
-- QR por apartamento, checklist por tipo de limpieza, 4 fotos de cierre y tiempos por apartamento.
-- Se ejecuta UNA vez: SQL Editor → pegar todo → Run.
-- Regla de la casa: todo UPDATE/DELETE lleva WHERE (Supabase bloquea los que no lo llevan).

-- 1. QR por propiedad ------------------------------------------------------
alter table public.propiedades
  add column if not exists qr_token text unique default replace(gen_random_uuid()::text, '-', '');
update public.propiedades set qr_token = replace(gen_random_uuid()::text, '-', '') where qr_token is null;
alter table public.propiedades alter column qr_token set not null;

-- 2. Checklist ---------------------------------------------------------------
create table if not exists public.checklist_pasos (
  id           int generated always as identity primary key,
  tipo         public.tipo_limpieza not null,
  orden        int not null,
  sala         text not null check (sala in ('kitchen', 'bathroom', 'bedroom', 'living', 'final')),
  texto_en     text not null check (length(texto_en) between 2 and 120),
  texto_es     text not null check (length(texto_es) between 2 and 120),
  obligatorio  boolean not null default true,
  activo       boolean not null default true,
  unique (tipo, orden)
);
alter table public.checklist_pasos enable row level security;
revoke all on public.checklist_pasos from anon;
revoke insert, update, delete, truncate on public.checklist_pasos from authenticated;
drop policy if exists "checklist: lectura" on public.checklist_pasos;
create policy "checklist: lectura" on public.checklist_pasos
  for select to authenticated using ((select public.mi_nivel()) is not null);

-- Progreso de cada limpieza
alter table public.limpiezas
  add column if not exists inicio_qr boolean,                          -- true = empezó escaneando el QR; false = "Can't scan"
  add column if not exists personas  int not null default 1 check (personas between 1 and 4),
  add column if not exists checklist jsonb not null default '{}'::jsonb; -- { "id_paso": "hora en que se marcó" }

-- 3. Fotos de cierre ---------------------------------------------------------
create table if not exists public.fotos_cierre (
  id           uuid primary key default gen_random_uuid(),
  limpieza_id  uuid not null references public.limpiezas(id) on delete cascade,
  sala         text not null check (sala in ('bedroom', 'bathroom', 'kitchen', 'living')),
  ruta         text not null,                 -- carpeta/archivo dentro del bucket fotos-cierre
  subida_en    timestamptz not null default now(),
  subida_por   uuid,
  unique (limpieza_id, sala)
);
alter table public.fotos_cierre enable row level security;
revoke all on public.fotos_cierre from anon;
revoke insert, update, delete, truncate on public.fotos_cierre from authenticated;

-- Bucket privado para las fotos
insert into storage.buckets (id, name, public) values ('fotos-cierre', 'fotos-cierre', false)
on conflict (id) do nothing;

-- ¿Puede quien llama subir esta foto? Solo el cleaner de una limpieza EN CURSO, en la carpeta de esa limpieza.
create or replace function public._puede_subir_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and l.asignada_a = (select auth.uid()) and l.publicada and l.estado = 'en_curso'
      and public.mi_nivel() is not null)
$$;
create or replace function public._puede_ver_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select public._lider_limpieza() or exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1) and l.asignada_a = (select auth.uid()) and public.mi_nivel() is not null)
$$;
revoke execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) from public, anon;
grant  execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) to authenticated;

-- Las filas de fotos las ven el cleaner de esa limpieza, el lider de limpieza y Operacion (misma regla que el bucket)
drop policy if exists "fotos: lectura" on public.fotos_cierre;
create policy "fotos: lectura" on public.fotos_cierre
  for select to authenticated using (public._puede_ver_foto(limpieza_id::text));

drop policy if exists "fotos-cierre: subir" on storage.objects;
drop policy if exists "fotos-cierre: repetir" on storage.objects;
drop policy if exists "fotos-cierre: ver" on storage.objects;
create policy "fotos-cierre: subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos-cierre' and public._puede_subir_foto(name));
create policy "fotos-cierre: repetir" on storage.objects for update to authenticated
  using (bucket_id = 'fotos-cierre' and public._puede_subir_foto(name))
  with check (bucket_id = 'fotos-cierre' and public._puede_subir_foto(name));
create policy "fotos-cierre: ver" on storage.objects for select to authenticated
  using (bucket_id = 'fotos-cierre' and public._puede_ver_foto(name));

-- 4. Funciones del cleaner ------------------------------------------------------
-- Empezar escaneando el QR del apartamento
create or replace function public.iniciar_con_qr(p_id uuid, p_qr text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_token text; v_cod text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'asignada' then raise exception 'Solo se puede empezar una limpieza asignada.'; end if;
  select qr_token, codigo into v_token, v_cod from public.propiedades where id = v.propiedad_id;
  -- El QR lleva "OPSFLOW:<token>"; se acepta tambien el token solo
  if coalesce(regexp_replace(btrim(p_qr), '^OPSFLOW:', ''), '') <> v_token then
    raise exception 'This QR is not for %.', v_cod;
  end if;
  update public.limpiezas set estado = 'en_curso', inicio = now(), inicio_qr = true where id = p_id;
  perform public._evento('limpieza iniciada (QR)', p_id, null);
end $$;

-- "Can't scan": empezar sin QR (queda marcado para el lider)
create or replace function public.iniciar_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'asignada' then raise exception 'Solo se puede empezar una limpieza asignada.'; end if;
  update public.limpiezas set estado = 'en_curso', inicio = now(), inicio_qr = false where id = p_id;
  perform public._evento('limpieza iniciada (sin QR)', p_id, null);
end $$;

-- Marcar o desmarcar un paso de la checklist
create or replace function public.marcar_paso(p_id uuid, p_paso int, p_hecho boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if not exists (select 1 from public.checklist_pasos where id = p_paso and tipo = v.tipo and activo) then
    raise exception 'Ese paso no es de esta limpieza.';
  end if;
  update public.limpiezas
     set checklist = case when p_hecho then checklist || jsonb_build_object(p_paso::text, now())
                          else checklist - p_paso::text end
   where id = p_id;
end $$;

-- Cuantas personas limpian (para que el tiempo medio sea justo)
create or replace function public.marcar_personas(p_id uuid, p_n int)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado not in ('asignada', 'en_curso') then raise exception 'Esta limpieza ya está cerrada.'; end if;
  if p_n not between 1 and 4 then raise exception 'Entre 1 y 4 personas.'; end if;
  update public.limpiezas set personas = p_n where id = p_id;
end $$;

-- Apuntar una foto ya subida al bucket
create or replace function public.registrar_foto(p_id uuid, p_sala text, p_ruta text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if p_sala not in ('bedroom', 'bathroom', 'kitchen', 'living') then raise exception 'Sala no válida.'; end if;
  if split_part(p_ruta, '/', 1) <> p_id::text then raise exception 'La foto no es de esta limpieza.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por)
  values (p_id, p_sala, p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
end $$;

-- Terminar: ahora exige los pasos obligatorios y las 4 fotos
create or replace function public.terminar_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_faltan int; v_fotos int;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  select count(*) into v_faltan from public.checklist_pasos p
   where p.tipo = v.tipo and p.activo and p.obligatorio and not (v.checklist ? p.id::text);
  if v_faltan > 0 then raise exception 'Checklist not finished: % step(s) left.', v_faltan; end if;
  select count(distinct sala) into v_fotos from public.fotos_cierre where limpieza_id = p_id;
  if v_fotos < 4 then raise exception 'Take the 4 photos first (% of 4).', v_fotos; end if;
  update public.limpiezas set estado = 'terminada', fin = now() where id = p_id;
  perform public._evento('limpieza terminada', p_id, null);
end $$;

-- La checklist de una limpieza, con lo hecho y las fotos (cleaner de esa limpieza, lider o Operacion)
create or replace function public.mi_checklist(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id;
  if not found or public.mi_nivel() is null
     or not (public._lider_limpieza() or (v.asignada_a = (select auth.uid()) and v.publicada)) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return jsonb_build_object(
    'inicio_qr', v.inicio_qr, 'personas', v.personas, 'estado', v.estado,
    'pasos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sala', p.sala, 'en', p.texto_en, 'es', p.texto_es,
                          'obligatorio', p.obligatorio, 'hecho', v.checklist ? p.id::text) order by p.orden)
                       from public.checklist_pasos p where p.tipo = v.tipo and p.activo), '[]'::jsonb),
    'fotos', coalesce((select jsonb_object_agg(f.sala, f.ruta) from public.fotos_cierre f where f.limpieza_id = p_id), '{}'::jsonb));
end $$;

-- 5. Tiempos ------------------------------------------------------------------
-- Por apartamento y tipo (lider de limpieza y Operacion). Solo limpiezas con QR, entre 10 min y 6 h.
create or replace function public.tiempos_aptos(p_dias int default 90)
returns table (codigo text, nombre text, tipo text, limpiezas bigint, media_min int, mediana_min int, ultima date)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación.'; end if;
  return query
  select p.codigo, p.nombre, l.tipo::text, count(*),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60))::int,
         round(percentile_cont(0.5) within group (order by extract(epoch from (l.fin - l.inicio)) / 60))::int,
         max(l.fecha)
  from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
  where l.estado = 'terminada' and l.inicio_qr and l.fin is not null and l.inicio is not null
    and l.fecha >= current_date - p_dias
    and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'
  group by p.codigo, p.nombre, l.tipo
  order by p.codigo, l.tipo::text;
end $$;

-- Por persona (solo Operacion)
create or replace function public.tiempos_personas(p_dias int default 90)
returns table (cleaner text, tipo text, limpiezas bigint, media_min int, sin_qr bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  return query
  select pf.nombre, l.tipo::text,
         count(*) filter (where l.inicio_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60)
               filter (where l.inicio_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'))::int,
         count(*) filter (where l.inicio_qr is false)
  from public.limpiezas l join public.perfiles pf on pf.id = l.asignada_a
  where l.estado = 'terminada' and l.fecha >= current_date - p_dias
  group by pf.nombre, l.tipo
  order by pf.nombre, l.tipo::text;
end $$;

-- 6. QR para imprimir (solo Operacion) -----------------------------------------
create or replace function public.qr_lista()
returns table (codigo text, nombre text, pueblo text, qr text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  return query select p.codigo, p.nombre, p.pueblo, 'OPSFLOW:' || p.qr_token
               from public.propiedades p where p.activa order by p.codigo;
end $$;

create or replace function public.regenerar_qr(p_propiedad uuid)
returns text language plpgsql security definer set search_path = ''
as $$
declare v text := replace(gen_random_uuid()::text, '-', '');
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  update public.propiedades set qr_token = v where id = p_propiedad;
  if not found then raise exception 'Esa propiedad no existe.'; end if;
  return 'OPSFLOW:' || v;
end $$;

-- 7. Fotos de mas de 30 dias (las usa la tarea de borrado; solo el servidor) ----------
create or replace function public.fotos_caducadas(p_dias int default 30)
returns table (ruta text)
language sql security definer set search_path = ''
as $$
  with b as (delete from public.fotos_cierre where subida_en < now() - make_interval(days => p_dias) returning fotos_cierre.ruta)
  select b.ruta from b
$$;

-- Permisos de ejecucion
revoke execute on function public.iniciar_con_qr(uuid, text), public.marcar_paso(uuid, int, boolean),
  public.marcar_personas(uuid, int), public.registrar_foto(uuid, text, text), public.mi_checklist(uuid),
  public.tiempos_aptos(int), public.tiempos_personas(int), public.qr_lista(), public.regenerar_qr(uuid)
  from public, anon;
grant execute on function public.iniciar_con_qr(uuid, text), public.marcar_paso(uuid, int, boolean),
  public.marcar_personas(uuid, int), public.registrar_foto(uuid, text, text), public.mi_checklist(uuid),
  public.tiempos_aptos(int), public.tiempos_personas(int), public.qr_lista(), public.regenerar_qr(uuid)
  to authenticated;
revoke execute on function public.fotos_caducadas(int) from public, anon, authenticated;
grant  execute on function public.fotos_caducadas(int) to service_role;

-- 8. Checklists por tipo (BORRADOR para que housekeeping corrija) -------------------
-- Se cargan solo si la tabla esta vacia, para no pisar cambios.
do $$
begin
  if exists (select 1 from public.checklist_pasos) then return; end if;

  -- NORMAL (checkout)
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('normal', 10, 'bedroom',  'Open windows and air the apartment',            'Abrir ventanas y ventilar', true),
  ('normal', 20, 'bedroom',  'Strip beds, make beds with clean linens',        'Quitar sábanas y hacer camas con linens limpios', true),
  ('normal', 30, 'bedroom',  'Dust surfaces, check under beds',                'Polvo en superficies, revisar debajo de camas', true),
  ('normal', 40, 'bathroom', 'Clean toilet, sink and shower',                  'Limpiar inodoro, lavabo y ducha', true),
  ('normal', 50, 'bathroom', 'Clean mirror and fittings',                      'Limpiar espejo y grifería', true),
  ('normal', 60, 'bathroom', 'Fresh towels and toilet paper',                  'Toallas limpias y papel higiénico', true),
  ('normal', 70, 'kitchen',  'Wash and put away dishes',                       'Lavar y guardar la vajilla', true),
  ('normal', 80, 'kitchen',  'Empty and wipe fridge',                          'Vaciar y limpiar la nevera', true),
  ('normal', 90, 'kitchen',  'Clean hob, microwave and counters',              'Limpiar placa, microondas y encimeras', true),
  ('normal',100, 'living',   'Dust and tidy living area',                      'Polvo y orden en el salón', true),
  ('normal',110, 'living',   'Vacuum and mop all floors',                      'Aspirar y fregar todos los suelos', true),
  ('normal',120, 'final',    'All trash out, new bags in bins',                'Toda la basura fuera, bolsas nuevas', true),
  ('normal',130, 'final',    'Restock amenities (soap, coffee, etc.)',         'Reponer amenities (jabón, café, etc.)', true),
  ('normal',140, 'final',    'Lights, AC off · windows closed · key back',     'Luces y AC apagados · ventanas cerradas · llave en su sitio', true),
  ('normal',150, 'final',    'Report anything broken or missing',              'Avisar de cualquier rotura o faltante', false);

  -- REFRESH (repaso sin huesped nuevo)
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('refresh', 10, 'bedroom',  'Air the apartment, smooth beds',                'Ventilar y estirar camas', true),
  ('refresh', 20, 'bathroom', 'Quick clean of toilet, sink and shower',        'Repaso de inodoro, lavabo y ducha', true),
  ('refresh', 30, 'kitchen',  'Wipe counters and sink',                        'Repasar encimeras y fregadero', true),
  ('refresh', 40, 'living',   'Dust surfaces and vacuum',                      'Polvo y aspirar', true),
  ('refresh', 50, 'final',    'Check amenities and trash',                     'Revisar amenities y basura', true),
  ('refresh', 60, 'final',    'Lights, AC off · windows closed',               'Luces y AC apagados · ventanas cerradas', true);

  -- DEEP: todo lo de normal + extras
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio)
  select 'deep', orden, sala, texto_en, texto_es, obligatorio from public.checklist_pasos where tipo = 'normal';
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('deep', 35, 'bedroom',  'Inside wardrobes and drawers',                    'Dentro de armarios y cajones', true),
  ('deep', 36, 'bedroom',  'Check mattresses and curtains',                   'Revisar colchones y cortinas', true),
  ('deep', 55, 'bathroom', 'Descale and clean grout',                         'Quitar cal y limpiar juntas', true),
  ('deep', 85, 'kitchen',  'Oven and fridge deep clean',                      'Horno y nevera a fondo', true),
  ('deep', 86, 'kitchen',  'Inside kitchen cupboards',                        'Dentro de los armarios de cocina', true),
  ('deep',105, 'living',   'Windows and glass inside',                        'Cristales y ventanas por dentro', true),
  ('deep',106, 'living',   'Behind and under furniture',                      'Detrás y debajo de los muebles', true);

  -- HUESPED DENTRO
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('huesped_dentro', 10, 'final',    'Greet guest · ask what they need',      'Saludar al huésped · preguntar qué necesita', true),
  ('huesped_dentro', 20, 'bathroom', 'Clean bathroom',                        'Limpiar el baño', true),
  ('huesped_dentro', 30, 'bathroom', 'Fresh towels',                          'Toallas limpias', true),
  ('huesped_dentro', 40, 'final',    'Take trash out',                        'Sacar la basura', true),
  ('huesped_dentro', 50, 'final',    'Do not touch personal items',           'No tocar objetos personales', true);

  -- PARA FOTO: normal + puesta en escena
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio)
  select 'foto', orden, sala, texto_en, texto_es, obligatorio from public.checklist_pasos where tipo = 'normal';
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('foto', 25, 'bedroom', 'Perfect beds, cushions in place',                  'Camas perfectas, cojines colocados', true),
  ('foto',115, 'living',  'No personal objects, staging done',                'Sin objetos personales, puesta en escena', true);

  -- POST MANTENIMIENTO
  insert into public.checklist_pasos (tipo, orden, sala, texto_en, texto_es, obligatorio) values
  ('post_mantenimiento', 10, 'living',   'Remove dust and debris from works',  'Quitar polvo y restos de la obra', true),
  ('post_mantenimiento', 20, 'living',   'Clean the repaired area',            'Limpiar la zona reparada', true),
  ('post_mantenimiento', 30, 'bathroom', 'Clean bathroom',                     'Limpiar el baño', true),
  ('post_mantenimiento', 40, 'living',   'Vacuum and mop floors',              'Aspirar y fregar suelos', true),
  ('post_mantenimiento', 50, 'final',    'Check everything works · lights off','Comprobar que todo funciona · luces apagadas', true);
end $$;


-- ═══════════════ 13-PEGAR-cierre.sql ═══════════════
-- OpsFlow · limpieza guiada v3: cierre del apartamento (9 oct 2026)
-- QR al entrar Y al salir · 3 preguntas de cierre (utiles, basura, llaves) · departamento Bodega.
-- Ejecutar DESPUES de 010. Se puede ejecutar varias veces.
-- Todo UPDATE/DELETE lleva WHERE (Supabase los bloquea si no).

-- 1. Departamento Bodega y pendiente de utiles ------------------------------
alter type public.tipo_pendiente add value if not exists 'utiles';
commit;  -- un valor nuevo de un tipo solo se puede usar después de confirmarlo
begin;
-- (en este archivo el valor nuevo se compara como texto: tipo::text = 'utiles')

do $$ declare c text; begin
  for c in select conname from pg_constraint
           where conrelid = 'public.perfiles'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%departamento%'
  loop execute format('alter table public.perfiles drop constraint %I', c); end loop;
end $$;
alter table public.perfiles add constraint perfiles_departamento_check
  check (departamento in ('Limpieza', 'Linens', 'Drivers', 'Bodega', 'Operación'));

-- Lider de bodega: ve los pendientes de utiles; drivers: tambien los utiles preparados de su zona
drop policy if exists "pendientes: lectura por rol" on public.pendientes;
create policy "pendientes: lectura por rol" on public.pendientes for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Linens' and tipo::text = 'linens')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Bodega' and tipo::text = 'utiles')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Drivers' and tipo::text in ('linens', 'recogida', 'utiles'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and limpieza_id in (select id from public.limpiezas where asignada_a = (select auth.uid())))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and zona = (select public.mi_zona())
       and (tipo::text = 'recogida' or (tipo::text in ('linens', 'utiles') and estado <> 'abierto')))
);

-- 2. Datos del cierre ----------------------------------------------------------
alter table public.limpiezas  add column if not exists fin_qr boolean;   -- true: termino escaneando el QR · false: "Can't scan"
alter table public.limpiezas  add column if not exists cierre jsonb;     -- {escoba, squeegee, recogedor, basura, llaves, motivo_llaves}
alter table public.pendientes add column if not exists foto text;        -- foto de la basura (ruta en fotos-cierre)

-- La foto de la basura se guarda como una sala mas ("basura")
do $$ declare c text; begin
  for c in select conname from pg_constraint
           where conrelid = 'public.fotos_cierre'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%sala%'
  loop execute format('alter table public.fotos_cierre drop constraint %I', c); end loop;
end $$;
alter table public.fotos_cierre add constraint fotos_cierre_sala_check
  check (sala in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura'));

-- 3. Quien ve las fotos: ademas, la foto de la basura la ven el lider de drivers y los drivers de esa zona
create or replace function public._puede_ver_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select public._lider_limpieza()
  or exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1) and l.asignada_a = (select auth.uid()) and public.mi_nivel() is not null)
  or (split_part(p_nombre, '/', 2) = 'basura.jpg' and public.mi_departamento() = 'Drivers' and exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and (public.mi_nivel() = 'lider' or l.zona = public.mi_zona())))
$$;
revoke execute on function public._puede_ver_foto(text) from public, anon;
grant  execute on function public._puede_ver_foto(text) to authenticated;
drop policy if exists "fotos: lectura" on public.fotos_cierre;
create policy "fotos: lectura" on public.fotos_cierre
  for select to authenticated using (public._puede_ver_foto(ruta));

-- 4. Cerrar el apartamento: 3 preguntas + QR, todo de una vez -------------------
-- p_qr: lo leido en la pegatina; null = "Can't scan" (termina igual, marcado salida sin QR)
create or replace function public.cerrar_limpieza(
  p_id uuid, p_qr text, p_escoba boolean, p_squeegee boolean, p_recogedor boolean,
  p_basura boolean, p_llaves boolean, p_motivo_llaves text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v public.limpiezas; v_faltan int; v_fotos int; v_prop public.propiedades; v_prio boolean;
  v_utiles text[] := '{}'; v_ids uuid[] := '{}'; v_id uuid; v_foto text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  select count(*) into v_faltan from public.checklist_pasos p
   where p.tipo = v.tipo and p.activo and p.obligatorio and not (v.checklist ? p.id::text);
  if v_faltan > 0 then raise exception 'Checklist not finished: % step(s) left.', v_faltan; end if;
  select count(distinct sala) into v_fotos from public.fotos_cierre
   where limpieza_id = p_id and sala in ('bedroom', 'bathroom', 'kitchen', 'living');
  if v_fotos < 4 then raise exception 'Take the 4 photos first (% of 4).', v_fotos; end if;
  if p_escoba is null or p_squeegee is null or p_recogedor is null or p_basura is null or p_llaves is null then
    raise exception 'Answer the 3 closing questions first.';
  end if;
  if p_basura then
    select ruta into v_foto from public.fotos_cierre where limpieza_id = p_id and sala = 'basura';
    if v_foto is null then raise exception 'Take a photo of the trash first.'; end if;
  end if;
  if not p_llaves and length(btrim(coalesce(p_motivo_llaves, ''))) < 3 then
    raise exception 'Write why the keys are not in the key box.';
  end if;
  select * into v_prop from public.propiedades where id = v.propiedad_id;
  if p_qr is not null and btrim(p_qr) <> 'OPSFLOW:' || v_prop.qr_token then
    raise exception 'This QR is not for %. Scan the sticker inside this apartment.', v_prop.codigo;
  end if;

  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  if not p_escoba    then v_utiles := v_utiles || 'escoba'::text; end if;
  if not p_squeegee  then v_utiles := v_utiles || 'squeegee'::text; end if;
  if not p_recogedor then v_utiles := v_utiles || 'recogedor'::text; end if;
  if cardinality(v_utiles) > 0 then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'utiles'::text::public.tipo_pendiente,
            'Falta: ' || array_to_string(v_utiles, ', '), cardinality(v_utiles), coalesce(v_prio, false), (select auth.uid()), v.es_prueba)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: faltan útiles', v.id, v_id);
  end if;
  if p_basura then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, foto)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'recogida', 'Basura dejada en el apto', 1, coalesce(v_prio, false),
            (select auth.uid()), v.es_prueba, v_foto)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: basura en el apto', v.id, v_id);
  end if;

  update public.limpiezas set estado = 'terminada', fin = now(), fin_qr = (p_qr is not null),
    cierre = jsonb_build_object('escoba', p_escoba, 'squeegee', p_squeegee, 'recogedor', p_recogedor,
                                'basura', p_basura, 'llaves', p_llaves,
                                'motivo_llaves', case when p_llaves then null else left(btrim(p_motivo_llaves), 200) end)
  where id = p_id;
  perform public._evento('limpieza terminada' || case when p_qr is null then ' (salida sin QR)' else '' end
                         || case when p_llaves then '' else ' · llaves NO en key box' end, p_id, null);
  return jsonb_build_object('pendientes', to_jsonb(v_ids), 'llaves', p_llaves);
end $$;

-- El Finish antiguo ya no cierra: obliga a pasar por el cierre (si alguien tiene la app vieja, se lo dice)
create or replace function public.terminar_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  raise exception 'Update the app: close the apartment and scan the QR to finish. · Actualiza la app.';
end $$;

-- 5. Funciones que cambian (utiles, bodega, foto de basura, QR de salida, avisos) -----
create or replace function public.registrar_foto(p_id uuid, p_sala text, p_ruta text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if p_sala not in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura') then raise exception 'Sala no válida.'; end if;
  if split_part(p_ruta, '/', 1) <> p_id::text then raise exception 'La foto no es de esta limpieza.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por)
  values (p_id, p_sala, p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
end $$;

create or replace function public.mi_ruta(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_zona public.zona := public.mi_zona();
begin
  if not (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers') then
    raise exception 'Esta pantalla es para drivers.';
  end if;
  return jsonb_build_object(
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'estado', pe.estado,
        'prioritario', pe.prioritario, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'foto', pe.foto)
        order by pe.prioritario desc, pe.creado_en)
      from public.pendientes pe
      join public.limpiezas l on l.id = pe.limpieza_id
      join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.fecha = p_fecha and pe.zona = v_zona
        and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto'))), '[]'::jsonb),
    'orden', coalesce((select jsonb_agg(jsonb_build_object(
        'cleaner', pf.nombre, 'orden', l.orden, 'estado', l.estado, 'codigo', p.codigo, 'nombre', p.nombre,
        'pueblo', p.pueblo, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by pf.nombre, l.orden)
      from public.limpiezas l
      join public.propiedades p on p.id = l.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      join public.perfiles pf on pf.id = l.asignada_a
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada), '[]'::jsonb));
end $$;

create or replace function public.marcar_preparado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found or v.tipo::text not in ('linens', 'utiles') then raise exception 'Ese pendiente no se prepara.'; end if;
  -- Linens lo prepara linens; los utiles (escoba, squeegee, recogedor) los prepara bodega
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = case when v.tipo::text = 'utiles' then 'Bodega' else 'Linens' end)) then
    raise exception 'Solo % u Operación marcan preparado.', case when v.tipo::text = 'utiles' then 'bodega' else 'linens' end;
  end if;
  if v.estado <> 'abierto' then raise exception 'Ese pendiente ya está preparado.'; end if;
  update public.pendientes set estado = 'preparado', preparado_por = (select auth.uid()), preparado_en = now() where id = p_id;
  perform public._evento('preparado por ' || case when v.tipo::text = 'utiles' then 'bodega' else 'linens' end, v.limpieza_id, p_id);
end $$;

create or replace function public.marcar_entregado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and public.mi_zona() = v.zona)) then
    raise exception 'Solo el driver de la zona puede marcar la entrega.';
  end if;
  if v.tipo = 'linens' and v.estado = 'preparado' then
    update public.pendientes set estado = 'entregado', entregado_por = (select auth.uid()), entregado_en = now() where id = p_id;
    perform public._evento('entregado por driver', v.limpieza_id, p_id);
  elsif v.tipo::text = 'utiles' and v.estado = 'preparado' then
    -- Utiles: el driver los deja en el apto y queda cerrado (no hay nadie que marque recibido)
    update public.pendientes set estado = 'cerrado', entregado_por = (select auth.uid()), entregado_en = now(),
                                 cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
    perform public._evento('útiles entregados por driver', v.limpieza_id, p_id);
  elsif v.tipo = 'recogida' and v.estado = 'abierto' then
    update public.pendientes set estado = 'cerrado', entregado_por = (select auth.uid()), entregado_en = now(),
                                 cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
    perform public._evento('recogido por driver', v.limpieza_id, p_id);
  else
    raise exception 'Ese pendiente todavía no está listo para el driver.';
  end if;
end $$;

create or replace function public.tablero(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'El tablero es de Operación.'; end if;
  return jsonb_build_object(
    'limpiezas', (select coalesce(jsonb_object_agg(estado, n), '{}'::jsonb)
                  from (select estado, count(*) n from public.limpiezas where fecha = p_fecha group by estado) a),
    'sin_publicar', (select count(*) from public.limpiezas where fecha = p_fecha and asignada_a is not null and not publicada),
    'en_linens',   (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'linens' and estado = 'abierto'),
    'en_bodega',   (select count(*) from public.pendientes where fecha = p_fecha and tipo::text = 'utiles' and estado = 'abierto'),
    'en_driver',   (select count(*) from public.pendientes where fecha = p_fecha and ((tipo::text in ('linens', 'utiles') and estado = 'preparado') or (tipo = 'recogida' and estado = 'abierto'))),
    'llaves_no',   (select coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'nombre', p.nombre, 'motivo', l.cierre->>'motivo_llaves')), '[]'::jsonb)
                    from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
                    where l.fecha = p_fecha and l.cierre->>'llaves' = 'false'),
    'por_recibir', (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'linens' and estado = 'entregado'),
    'otros_abiertos', (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'otro' and estado = 'abierto'),
    'cerrados',    (select count(*) from public.pendientes where fecha = p_fecha and estado = 'cerrado'),
    'minutos_cierre', (select round(avg(extract(epoch from cerrado_en - creado_en)) / 60)
                       from public.pendientes where fecha = p_fecha and estado = 'cerrado'),
    'no_pude_entrar', (select coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'nombre', p.nombre, 'motivo', l.motivo_no_entrar)), '[]'::jsonb)
                       from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
                       where l.fecha = p_fecha and l.estado = 'no_pude_entrar'));
end $$;

create or replace function public.mi_checklist(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id;
  if not found or public.mi_nivel() is null
     or not (public._lider_limpieza() or (v.asignada_a = (select auth.uid()) and v.publicada)) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return jsonb_build_object(
    'inicio_qr', v.inicio_qr, 'fin_qr', v.fin_qr, 'cierre', v.cierre, 'personas', v.personas, 'estado', v.estado,
    'pasos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sala', p.sala, 'en', p.texto_en, 'es', p.texto_es,
                          'obligatorio', p.obligatorio, 'hecho', v.checklist ? p.id::text) order by p.orden)
                       from public.checklist_pasos p where p.tipo = v.tipo and p.activo), '[]'::jsonb),
    'fotos', coalesce((select jsonb_object_agg(f.sala, f.ruta) from public.fotos_cierre f where f.limpieza_id = p_id), '{}'::jsonb));
end $$;

create or replace function public.tiempos_aptos(p_dias int default 90)
returns table (codigo text, nombre text, tipo text, limpiezas bigint, media_min int, mediana_min int, ultima date)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación.'; end if;
  return query
  select p.codigo, p.nombre, l.tipo::text, count(*),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60))::int,
         round(percentile_cont(0.5) within group (order by extract(epoch from (l.fin - l.inicio)) / 60))::int,
         max(l.fecha)
  from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
  where l.estado = 'terminada' and l.inicio_qr and l.fin_qr and l.fin is not null and l.inicio is not null
    and l.fecha >= current_date - p_dias
    and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'
  group by p.codigo, p.nombre, l.tipo
  order by p.codigo, l.tipo::text;
end $$;

create or replace function public.tiempos_personas(p_dias int default 90)
returns table (cleaner text, tipo text, limpiezas bigint, media_min int, sin_qr bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  return query
  select pf.nombre, l.tipo::text,
         count(*) filter (where l.inicio_qr and l.fin_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60)
               filter (where l.inicio_qr and l.fin_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'))::int,
         count(*) filter (where l.inicio_qr is false or l.fin_qr is false)
  from public.limpiezas l join public.perfiles pf on pf.id = l.asignada_a
  where l.estado = 'terminada' and l.fecha >= current_date - p_dias
  group by pf.nombre, l.tipo
  order by pf.nombre, l.tipo::text;
end $$;

-- Avisos: utiles → bodega → drivers; basura → drivers + lider de drivers; llaves → lideres
create or replace function public.avisos_para(p_tipo text, p_id uuid default null, p_fecha date default null)
returns table (perfil_id uuid, titulo text, cuerpo text, url text, clave text, telefonos jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  pe public.pendientes; li public.limpiezas; pr public.propiedades; ck public.checkouts;
  v_aviso text; v_ok boolean := true;
begin
  create temp table if not exists _dest (perfil_id uuid, idioma text, t_es text, t_en text, c_es text, c_en text, url text, clave text) on commit drop;
  truncate _dest;

  if p_tipo = 'pendiente' then
    select * into pe from public.pendientes where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = pe.propiedad_id;
    select c.* into ck from public.checkouts c join public.limpiezas l on l.checkout_id = c.id where l.id = pe.limpieza_id;
    v_aviso := 'pendiente:' || pe.id || ':' || pe.estado;

    if pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || pe.cantidad || ' × ' || pe.detalle, 'Linens: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || pe.cantidad || ' × ' || pe.detalle, 'Deliver: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.foto is not null then
      -- 4b. Basura dejada en el apto (con foto) → drivers de la zona y lider de drivers
      insert into _dest select p.id, p.idioma,
        'Basura en el apto: ' || pr.codigo, 'Trash left: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.detalle, pr.pueblo || ' · pick it up (photo in the app)',
        './', null
      from public.perfiles p where p.activo and p.departamento = 'Drivers'
        and ((p.nivel = 'operador' and p.zona = pe.zona) or (p.nivel = 'lider' and (p.zona is null or p.zona = pe.zona)));

    elsif pe.tipo::text = 'utiles' and pe.estado = 'abierto' then
      -- 8. Faltan utiles → lider de bodega
      insert into _dest select p.id, p.idioma,
        'Útiles: ' || pe.detalle, 'Tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=bodega', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Bodega'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo::text = 'utiles' and pe.estado = 'preparado' then
      -- 9. Utiles preparados → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar útiles: ' || pe.detalle, 'Deliver tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' then
      -- 4. Recogida → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Recoger: basura y linens sucios', 'Pick up: trash & dirty linens',
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'linens' and pe.estado = 'entregado' then
      -- 5. Entregado → el cleaner que lo pidio
      insert into _dest select p.id, p.idioma,
        'Entregado: ' || pe.cantidad || ' × ' || pe.detalle, 'Delivered: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=seguimiento', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en where true;  -- Supabase exige WHERE en todo UPDATE
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    if li.estado = 'terminada' and li.cierre->>'llaves' = 'false' then
      -- 10. Llaves NO dejadas en el key box → lider de limpieza y lider de drivers (urgente)
      insert into _dest select p.id, p.idioma,
        '⚠ Llaves NO en el key box: ' || pr.codigo, '⚠ Keys NOT in the key box: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''), pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''),
        case when p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, 'limpieza:' || li.id || ':llaves:' || p.id
      from public.perfiles p
      where p.activo and p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona);
      v_aviso := 'limpieza:' || li.id || ':llaves';
    elsif li.estado <> 'no_pude_entrar' then
      return;
    else
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));
    end if;

  elsif p_tipo = 'orden' then
    if p_fecha is null then return; end if;
    -- 1. Orden publicado → cada cleaner con limpiezas publicadas ese dia
    --    (la clave lleva cuantas tiene: si el lider le anade otra y publica, le vuelve a sonar)
    insert into _dest select p.id, p.idioma,
      'Orden de limpieza listo', 'Your cleaning order is ready',
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartamento' || case when count(*) > 1 then 's' else '' end,
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartment' || case when count(*) > 1 then 's' else '' end,
      './', 'orden:' || p_fecha || ':' || p.id || ':' || count(*)
    from public.limpiezas l join public.perfiles p on p.id = l.asignada_a
    where l.fecha = p_fecha and l.publicada and p.activo
    group by p.id, p.idioma;

  else
    return;
  end if;

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id) where true;

  -- Apuntar los nuevos; los que ya estaban apuntados no salen otra vez
  return query
  with nuevos as (
    insert into public.avisos_enviados (clave, perfil_id, titulo)
    select d.clave, d.perfil_id, case when d.idioma = 'es' then d.t_es else d.t_en end from _dest d
    on conflict (clave) do nothing
    returning avisos_enviados.clave
  )
  select d.perfil_id,
         case when d.idioma = 'es' then d.t_es else d.t_en end,
         case when d.idioma = 'es' then d.c_es else d.c_en end,
         d.url, d.clave,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                   from public.suscripciones s where s.perfil_id = d.perfil_id), '[]'::jsonb)
  from _dest d join nuevos n on n.clave = d.clave;
end $$;

-- 6. Permisos -------------------------------------------------------------------
revoke execute on function public.cerrar_limpieza(uuid, text, boolean, boolean, boolean, boolean, boolean, text) from public, anon;
grant  execute on function public.cerrar_limpieza(uuid, text, boolean, boolean, boolean, boolean, boolean, text) to authenticated;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;


-- ═══════════════ 15-PEGAR-linens.sql ═══════════════
-- OpsFlow · limpieza guiada v4: revisión de linens al empezar y reporte único (10 oct 2026)
-- Después del QR, el cleaner revisa la bolsa: reporta todo lo que falta en UN pedido, o "Nothing missing".
-- Hasta entonces no puede marcar pasos, subir fotos ni cerrar. Ejecutar DESPUES de 013. Se puede ejecutar varias veces.
-- Todo UPDATE/DELETE lleva WHERE (Supabase los bloquea si no).

-- 1. Datos nuevos -----------------------------------------------------------------
alter table public.limpiezas  add column if not exists linens_revisado timestamptz;  -- cuándo hizo la revisión de linens
alter table public.pendientes add column if not exists items jsonb;                  -- [{"item": "sabana_doble", "cantidad": 2}, ...]

-- Artículos de la bolsa de linens (clave, nombre en español para linens)
create or replace function public._linens_nombre(p_item text)
returns text language sql immutable set search_path = ''
as $$
  select case p_item
    when 'sabana_doble' then 'Sábana doble'            when 'sabana_sencilla' then 'Sábana sencilla'
    when 'funda_duvet_doble' then 'Funda duvet doble'  when 'funda_duvet_sencilla' then 'Funda duvet sencilla'
    when 'funda_almohada' then 'Funda de almohada'     when 'toalla_grande' then 'Toalla grande'
    when 'toalla_pequena' then 'Toalla pequeña'        when 'alfombra_bano' then 'Alfombra de baño'
    when 'toalla_cocina' then 'Toalla de cocina'       when 'esponja' then 'Esponja'
    when 'papel_higienico' then 'Papel higiénico'      else null end
$$;
revoke execute on function public._linens_nombre(text) from public, anon, authenticated;

-- Texto del pedido para los avisos: "2 × Sábana doble · 1 × Toalla grande" / "2 × Double sheet · 1 × Large towel"
create or replace function public._linens_texto(p_items jsonb, p_idioma text)
returns text language sql immutable set search_path = ''
as $$
  select string_agg((x->>'cantidad') || ' × ' || case when p_idioma = 'es' then public._linens_nombre(x->>'item') else
    case x->>'item'
      when 'sabana_doble' then 'Double sheet'           when 'sabana_sencilla' then 'Single sheet'
      when 'funda_duvet_doble' then 'Double duvet cover' when 'funda_duvet_sencilla' then 'Single duvet cover'
      when 'funda_almohada' then 'Pillowcase'           when 'toalla_grande' then 'Large towel'
      when 'toalla_pequena' then 'Small towel'          when 'alfombra_bano' then 'Bath mat'
      when 'toalla_cocina' then 'Kitchen towel'         when 'esponja' then 'Sponge'
      when 'papel_higienico' then 'Toilet paper'        else x->>'item' end end, ' · ')
  from jsonb_array_elements(p_items) x
$$;
revoke execute on function public._linens_texto(jsonb, text) from public, anon, authenticated;

-- 2. Revisión de linens --------------------------------------------------------------
-- Reporte único: varios artículos con cantidad → UN pendiente de linens
create or replace function public.reportar_linens(p_limpieza uuid, p_items jsonb)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_prio boolean; v_id uuid; v_items jsonb; v_total int; v_texto text; v_malo int;
begin
  v := public._mi_limpieza(p_limpieza);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Choose at least one item.';
  end if;
  -- Validar: artículos conocidos, cantidades 1..50, sin repetir
  select count(*) into v_malo from jsonb_array_elements(p_items) x
   where public._linens_nombre(x->>'item') is null
      or jsonb_typeof(x->'cantidad') is distinct from 'number'
      or (x->>'cantidad')::numeric not between 1 and 50 or (x->>'cantidad')::numeric <> floor((x->>'cantidad')::numeric);
  if v_malo > 0 then raise exception 'Item or quantity not valid.'; end if;
  if (select count(distinct x->>'item') from jsonb_array_elements(p_items) x) <> jsonb_array_length(p_items) then
    raise exception 'Each item only once (use the quantity).';
  end if;
  select jsonb_agg(jsonb_build_object('item', x->>'item', 'cantidad', (x->>'cantidad')::int)),
         sum((x->>'cantidad')::int),
         string_agg((x->>'cantidad') || ' × ' || public._linens_nombre(x->>'item'), ' · ')
    into v_items, v_total, v_texto
    from jsonb_array_elements(p_items) x;
  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, items)
  values (v.id, v.propiedad_id, v.zona, v.fecha, 'linens', left(v_texto, 200), least(v_total, 50), coalesce(v_prio, false),
          (select auth.uid()), v.es_prueba, v_items)
  returning id into v_id;
  update public.limpiezas set linens_revisado = coalesce(linens_revisado, now()) where id = v.id;
  perform public._evento('linens reportados (' || v_total || ')', v.id, v_id);
  return v_id;
end $$;

-- "Nothing missing": la bolsa está completa
create or replace function public.linens_ok(p_limpieza uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_limpieza);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  update public.limpiezas set linens_revisado = coalesce(linens_revisado, now()) where id = v.id;
  perform public._evento('linens revisados: nada falta', v.id, null);
end $$;

-- 3. Checklist, fotos y cierre: bloqueados hasta la revisión de linens ---------------
create or replace function public.marcar_paso(p_id uuid, p_paso int, p_hecho boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  if not exists (select 1 from public.checklist_pasos where id = p_paso and tipo = v.tipo and activo) then
    raise exception 'Ese paso no es de esta limpieza.';
  end if;
  update public.limpiezas
     set checklist = case when p_hecho then checklist || jsonb_build_object(p_paso::text, now())
                          else checklist - p_paso::text end
   where id = p_id;
end $$;

create or replace function public.registrar_foto(p_id uuid, p_sala text, p_ruta text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  if p_sala not in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura') then raise exception 'Sala no válida.'; end if;
  if split_part(p_ruta, '/', 1) <> p_id::text then raise exception 'La foto no es de esta limpieza.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por)
  values (p_id, p_sala, p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
end $$;

create or replace function public.cerrar_limpieza(
  p_id uuid, p_qr text, p_escoba boolean, p_squeegee boolean, p_recogedor boolean,
  p_basura boolean, p_llaves boolean, p_motivo_llaves text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v public.limpiezas; v_faltan int; v_fotos int; v_prop public.propiedades; v_prio boolean;
  v_utiles text[] := '{}'; v_ids uuid[] := '{}'; v_id uuid; v_foto text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  select count(*) into v_faltan from public.checklist_pasos p
   where p.tipo = v.tipo and p.activo and p.obligatorio and not (v.checklist ? p.id::text);
  if v_faltan > 0 then raise exception 'Checklist not finished: % step(s) left.', v_faltan; end if;
  select count(distinct sala) into v_fotos from public.fotos_cierre
   where limpieza_id = p_id and sala in ('bedroom', 'bathroom', 'kitchen', 'living');
  if v_fotos < 4 then raise exception 'Take the 4 photos first (% of 4).', v_fotos; end if;
  if p_escoba is null or p_squeegee is null or p_recogedor is null or p_basura is null or p_llaves is null then
    raise exception 'Answer the 3 closing questions first.';
  end if;
  if p_basura then
    select ruta into v_foto from public.fotos_cierre where limpieza_id = p_id and sala = 'basura';
    if v_foto is null then raise exception 'Take a photo of the trash first.'; end if;
  end if;
  if not p_llaves and length(btrim(coalesce(p_motivo_llaves, ''))) < 3 then
    raise exception 'Write why the keys are not in the key box.';
  end if;
  select * into v_prop from public.propiedades where id = v.propiedad_id;
  if p_qr is not null and btrim(p_qr) <> 'OPSFLOW:' || v_prop.qr_token then
    raise exception 'This QR is not for %. Scan the sticker inside this apartment.', v_prop.codigo;
  end if;

  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  if not p_escoba    then v_utiles := v_utiles || 'escoba'::text; end if;
  if not p_squeegee  then v_utiles := v_utiles || 'squeegee'::text; end if;
  if not p_recogedor then v_utiles := v_utiles || 'recogedor'::text; end if;
  if cardinality(v_utiles) > 0 then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'utiles'::text::public.tipo_pendiente,
            'Falta: ' || array_to_string(v_utiles, ', '), cardinality(v_utiles), coalesce(v_prio, false), (select auth.uid()), v.es_prueba)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: faltan útiles', v.id, v_id);
  end if;
  if p_basura then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, foto)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'recogida', 'Basura dejada en el apto', 1, coalesce(v_prio, false),
            (select auth.uid()), v.es_prueba, v_foto)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: basura en el apto', v.id, v_id);
  end if;

  update public.limpiezas set estado = 'terminada', fin = now(), fin_qr = (p_qr is not null),
    cierre = jsonb_build_object('escoba', p_escoba, 'squeegee', p_squeegee, 'recogedor', p_recogedor,
                                'basura', p_basura, 'llaves', p_llaves,
                                'motivo_llaves', case when p_llaves then null else left(btrim(p_motivo_llaves), 200) end)
  where id = p_id;
  perform public._evento('limpieza terminada' || case when p_qr is null then ' (salida sin QR)' else '' end
                         || case when p_llaves then '' else ' · llaves NO en key box' end, p_id, null);
  return jsonb_build_object('pendientes', to_jsonb(v_ids), 'llaves', p_llaves);
end $$;

-- 4. Pantallas: los artículos del reporte llegan a cleaner y driver; la checklist sabe si ya revisó -----
create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden, 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar, 'linens_revisado', l.linens_revisado,
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado, 'items', pe.items) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and l.asignada_a = (select auth.uid())
      and public.mi_nivel() is not null
  ) t
$$;

create or replace function public.mi_ruta(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_zona public.zona := public.mi_zona();
begin
  if not (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers') then
    raise exception 'Esta pantalla es para drivers.';
  end if;
  return jsonb_build_object(
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'estado', pe.estado,
        'prioritario', pe.prioritario, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'foto', pe.foto, 'items', pe.items)
        order by pe.prioritario desc, pe.creado_en)
      from public.pendientes pe
      join public.limpiezas l on l.id = pe.limpieza_id
      join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.fecha = p_fecha and pe.zona = v_zona
        and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto'))), '[]'::jsonb),
    'orden', coalesce((select jsonb_agg(jsonb_build_object(
        'cleaner', pf.nombre, 'orden', l.orden, 'estado', l.estado, 'codigo', p.codigo, 'nombre', p.nombre,
        'pueblo', p.pueblo, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by pf.nombre, l.orden)
      from public.limpiezas l
      join public.propiedades p on p.id = l.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      join public.perfiles pf on pf.id = l.asignada_a
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada), '[]'::jsonb));
end $$;

create or replace function public.mi_checklist(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id;
  if not found or public.mi_nivel() is null
     or not (public._lider_limpieza() or (v.asignada_a = (select auth.uid()) and v.publicada)) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return jsonb_build_object(
    'inicio_qr', v.inicio_qr, 'fin_qr', v.fin_qr, 'linens_revisado', v.linens_revisado, 'cierre', v.cierre, 'personas', v.personas, 'estado', v.estado,
    'pasos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sala', p.sala, 'en', p.texto_en, 'es', p.texto_es,
                          'obligatorio', p.obligatorio, 'hecho', v.checklist ? p.id::text) order by p.orden)
                       from public.checklist_pasos p where p.tipo = v.tipo and p.activo), '[]'::jsonb),
    'fotos', coalesce((select jsonb_object_agg(f.sala, f.ruta) from public.fotos_cierre f where f.limpieza_id = p_id), '{}'::jsonb));
end $$;

-- Avisos: el pedido completo en un solo aviso, en el idioma de cada persona
create or replace function public.avisos_para(p_tipo text, p_id uuid default null, p_fecha date default null)
returns table (perfil_id uuid, titulo text, cuerpo text, url text, clave text, telefonos jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  pe public.pendientes; li public.limpiezas; pr public.propiedades; ck public.checkouts;
  v_aviso text; v_ok boolean := true;
begin
  create temp table if not exists _dest (perfil_id uuid, idioma text, t_es text, t_en text, c_es text, c_en text, url text, clave text) on commit drop;
  truncate _dest;

  if p_tipo = 'pendiente' then
    select * into pe from public.pendientes where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = pe.propiedad_id;
    select c.* into ck from public.checkouts c join public.limpiezas l on l.checkout_id = c.id where l.id = pe.limpieza_id;
    v_aviso := 'pendiente:' || pe.id || ':' || pe.estado;

    if pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Deliver: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.foto is not null then
      -- 4b. Basura dejada en el apto (con foto) → drivers de la zona y lider de drivers
      insert into _dest select p.id, p.idioma,
        'Basura en el apto: ' || pr.codigo, 'Trash left: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.detalle, pr.pueblo || ' · pick it up (photo in the app)',
        './', null
      from public.perfiles p where p.activo and p.departamento = 'Drivers'
        and ((p.nivel = 'operador' and p.zona = pe.zona) or (p.nivel = 'lider' and (p.zona is null or p.zona = pe.zona)));

    elsif pe.tipo::text = 'utiles' and pe.estado = 'abierto' then
      -- 8. Faltan utiles → lider de bodega
      insert into _dest select p.id, p.idioma,
        'Útiles: ' || pe.detalle, 'Tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=bodega', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Bodega'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo::text = 'utiles' and pe.estado = 'preparado' then
      -- 9. Utiles preparados → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar útiles: ' || pe.detalle, 'Deliver tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' then
      -- 4. Recogida → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Recoger: basura y linens sucios', 'Pick up: trash & dirty linens',
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'linens' and pe.estado = 'entregado' then
      -- 5. Entregado → el cleaner que lo pidio
      insert into _dest select p.id, p.idioma,
        'Entregado: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Delivered: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=seguimiento', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en where true;  -- Supabase exige WHERE en todo UPDATE
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    if li.estado = 'terminada' and li.cierre->>'llaves' = 'false' then
      -- 10. Llaves NO dejadas en el key box → lider de limpieza y lider de drivers (urgente)
      insert into _dest select p.id, p.idioma,
        '⚠ Llaves NO en el key box: ' || pr.codigo, '⚠ Keys NOT in the key box: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''), pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''),
        case when p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, 'limpieza:' || li.id || ':llaves:' || p.id
      from public.perfiles p
      where p.activo and p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona);
      v_aviso := 'limpieza:' || li.id || ':llaves';
    elsif li.estado <> 'no_pude_entrar' then
      return;
    else
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));
    end if;

  elsif p_tipo = 'orden' then
    if p_fecha is null then return; end if;
    -- 1. Orden publicado → cada cleaner con limpiezas publicadas ese dia
    --    (la clave lleva cuantas tiene: si el lider le anade otra y publica, le vuelve a sonar)
    insert into _dest select p.id, p.idioma,
      'Orden de limpieza listo', 'Your cleaning order is ready',
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartamento' || case when count(*) > 1 then 's' else '' end,
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartment' || case when count(*) > 1 then 's' else '' end,
      './', 'orden:' || p_fecha || ':' || p.id || ':' || count(*)
    from public.limpiezas l join public.perfiles p on p.id = l.asignada_a
    where l.fecha = p_fecha and l.publicada and p.activo
    group by p.id, p.idioma;

  else
    return;
  end if;

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id) where true;

  -- Apuntar los nuevos; los que ya estaban apuntados no salen otra vez
  return query
  with nuevos as (
    insert into public.avisos_enviados (clave, perfil_id, titulo)
    select d.clave, d.perfil_id, case when d.idioma = 'es' then d.t_es else d.t_en end from _dest d
    on conflict (clave) do nothing
    returning avisos_enviados.clave
  )
  select d.perfil_id,
         case when d.idioma = 'es' then d.t_es else d.t_en end,
         case when d.idioma = 'es' then d.c_es else d.c_en end,
         d.url, d.clave,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                   from public.suscripciones s where s.perfil_id = d.perfil_id), '[]'::jsonb)
  from _dest d join nuevos n on n.clave = d.clave;
end $$;

-- 5. Permisos -------------------------------------------------------------------------
revoke execute on function public.reportar_linens(uuid, jsonb), public.linens_ok(uuid) from public, anon;
grant  execute on function public.reportar_linens(uuid, jsonb), public.linens_ok(uuid) to authenticated;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;


-- ═══════════════ 17-PEGAR-mejoras.sql ═══════════════
-- OpsFlow · mejoras antes del piloto (10 oct 2026)
-- Cancelar y reabrir limpiezas · códigos QR solo para Operación · GPS al escanear · "no pude entregar" del driver
-- Zona horaria de Malta · informe del piloto · historial de cada limpieza.
-- Ejecutar DESPUES de 015. Se puede ejecutar varias veces. Todo UPDATE/DELETE lleva WHERE.

-- 1. Datos nuevos -----------------------------------------------------------------
alter type public.estado_limpieza add value if not exists 'cancelada';
commit;  -- un valor nuevo de un tipo solo se puede usar después de confirmarlo
begin;
-- (en este archivo el valor nuevo se compara como texto: estado::text = 'cancelada')
alter table public.limpiezas   add column if not exists cancelada_motivo text;
alter table public.limpiezas   add column if not exists reabierta_en timestamptz;
alter table public.limpiezas   add column if not exists gps jsonb;            -- {"inicio": {"dist": 35, "prec": 20}, "fin": {...}}
alter table public.propiedades add column if not exists lat double precision;
alter table public.propiedades add column if not exists lng double precision;
alter table public.pendientes  add column if not exists incidencia text;     -- el driver no pudo entregar/recoger
alter table public.pendientes  add column if not exists incidencia_en timestamptz;

-- 2. Los códigos QR solo los ve Operación (antes cualquier líder podía leerlos de la tabla) ----
revoke select on public.propiedades from authenticated;
grant select (id, codigo, nombre, zona, pueblo, direccion, mapa_url, camas_dobles, camas_indiv, sofas_cama, banos,
              notas, activa, es_prueba, creado_en, lat, lng) on public.propiedades to authenticated;
-- Las coordenadas las edita Operación igual que el resto de la ficha
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'propiedades_coordenadas_check') then
    alter table public.propiedades add constraint propiedades_coordenadas_check
      check ((lat is null and lng is null) or (lat between -90 and 90 and lng between -180 and 180));
  end if;
end $$;

-- 3. GPS al escanear: distancia (en metros) entre el teléfono y el apartamento -------------
create or replace function public._distancia_m(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns int language sql immutable set search_path = ''
as $$
  select round(2 * 6371000 * asin(sqrt(
    power(sin(radians(b_lat - a_lat) / 2), 2) +
    cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2))))::int
$$;
-- Resultado guardado: dist (null si el apto no tiene coordenadas), prec (precisión del teléfono), sin_gps
create or replace function public._gps(p_prop uuid, p_lat double precision, p_lng double precision, p_prec double precision)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_lat double precision; v_lng double precision;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return jsonb_build_object('sin_gps', true);
  end if;
  select lat, lng into v_lat, v_lng from public.propiedades where id = p_prop;
  return jsonb_build_object('sin_gps', false,
    'dist', case when v_lat is null then null else public._distancia_m(v_lat, v_lng, p_lat, p_lng) end,
    'prec', case when p_prec is null or p_prec < 0 then null else least(round(p_prec), 100000)::int end);
end $$;
revoke execute on function public._distancia_m(double precision, double precision, double precision, double precision),
  public._gps(uuid, double precision, double precision, double precision) from public, anon, authenticated;

-- Empezar y cerrar ahora reciben la posición del teléfono (opcional: si el cleaner no da permiso, queda "sin GPS")
drop function if exists public.iniciar_con_qr(uuid, text);
drop function if exists public.iniciar_limpieza(uuid);
drop function if exists public.cerrar_limpieza(uuid, text, boolean, boolean, boolean, boolean, boolean, text);

create or replace function public.iniciar_con_qr(p_id uuid, p_qr text, p_lat double precision default null, p_lng double precision default null, p_prec double precision default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_token text; v_cod text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'asignada' then raise exception 'Solo se puede empezar una limpieza asignada.'; end if;
  select qr_token, codigo into v_token, v_cod from public.propiedades where id = v.propiedad_id;
  -- El QR lleva "OPSFLOW:<token>"; se acepta tambien el token solo
  if coalesce(regexp_replace(btrim(p_qr), '^OPSFLOW:', ''), '') <> v_token then
    raise exception 'This QR is not for %.', v_cod;
  end if;
  update public.limpiezas set estado = 'en_curso', inicio = now(), inicio_qr = true,
    gps = jsonb_build_object('inicio', public._gps(v.propiedad_id, p_lat, p_lng, p_prec)) where id = p_id;
  perform public._evento('limpieza iniciada (QR)', p_id, null);
end $$;

create or replace function public.iniciar_limpieza(p_id uuid, p_lat double precision default null, p_lng double precision default null, p_prec double precision default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'asignada' then raise exception 'Solo se puede empezar una limpieza asignada.'; end if;
  update public.limpiezas set estado = 'en_curso', inicio = now(), inicio_qr = false,
    gps = jsonb_build_object('inicio', public._gps(v.propiedad_id, p_lat, p_lng, p_prec)) where id = p_id;
  perform public._evento('limpieza iniciada (sin QR)', p_id, null);
end $$;

create or replace function public.cerrar_limpieza(
  p_id uuid, p_qr text, p_escoba boolean, p_squeegee boolean, p_recogedor boolean,
  p_basura boolean, p_llaves boolean, p_motivo_llaves text default null, p_lat double precision default null, p_lng double precision default null, p_prec double precision default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v public.limpiezas; v_faltan int; v_fotos int; v_prop public.propiedades; v_prio boolean;
  v_utiles text[] := '{}'; v_ids uuid[] := '{}'; v_id uuid; v_foto text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  select count(*) into v_faltan from public.checklist_pasos p
   where p.tipo = v.tipo and p.activo and p.obligatorio and not (v.checklist ? p.id::text);
  if v_faltan > 0 then raise exception 'Checklist not finished: % step(s) left.', v_faltan; end if;
  select count(distinct sala) into v_fotos from public.fotos_cierre
   where limpieza_id = p_id and sala in ('bedroom', 'bathroom', 'kitchen', 'living');
  if v_fotos < 4 then raise exception 'Take the 4 photos first (% of 4).', v_fotos; end if;
  if p_escoba is null or p_squeegee is null or p_recogedor is null or p_basura is null or p_llaves is null then
    raise exception 'Answer the 3 closing questions first.';
  end if;
  if p_basura then
    select ruta into v_foto from public.fotos_cierre where limpieza_id = p_id and sala = 'basura';
    if v_foto is null then raise exception 'Take a photo of the trash first.'; end if;
  end if;
  if not p_llaves and length(btrim(coalesce(p_motivo_llaves, ''))) < 3 then
    raise exception 'Write why the keys are not in the key box.';
  end if;
  select * into v_prop from public.propiedades where id = v.propiedad_id;
  if p_qr is not null and btrim(p_qr) <> 'OPSFLOW:' || v_prop.qr_token then
    raise exception 'This QR is not for %. Scan the sticker inside this apartment.', v_prop.codigo;
  end if;

  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  if not p_escoba    then v_utiles := v_utiles || 'escoba'::text; end if;
  if not p_squeegee  then v_utiles := v_utiles || 'squeegee'::text; end if;
  if not p_recogedor then v_utiles := v_utiles || 'recogedor'::text; end if;
  if cardinality(v_utiles) > 0 then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'utiles'::text::public.tipo_pendiente,
            'Falta: ' || array_to_string(v_utiles, ', '), cardinality(v_utiles), coalesce(v_prio, false), (select auth.uid()), v.es_prueba)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: faltan útiles', v.id, v_id);
  end if;
  if p_basura then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, foto)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'recogida', 'Basura dejada en el apto', 1, coalesce(v_prio, false),
            (select auth.uid()), v.es_prueba, v_foto)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: basura en el apto', v.id, v_id);
  end if;

  update public.limpiezas set estado = 'terminada', fin = now(), fin_qr = (p_qr is not null),
    gps = coalesce(gps, '{}'::jsonb) || jsonb_build_object('fin', public._gps(v.propiedad_id, p_lat, p_lng, p_prec)),
    cierre = jsonb_build_object('escoba', p_escoba, 'squeegee', p_squeegee, 'recogedor', p_recogedor,
                                'basura', p_basura, 'llaves', p_llaves,
                                'motivo_llaves', case when p_llaves then null else left(btrim(p_motivo_llaves), 200) end)
  where id = p_id;
  perform public._evento('limpieza terminada' || case when p_qr is null then ' (salida sin QR)' else '' end
                         || case when p_llaves then '' else ' · llaves NO en key box' end, p_id, null);
  return jsonb_build_object('pendientes', to_jsonb(v_ids), 'llaves', p_llaves);
end $$;

-- 4. Cancelar y reabrir limpiezas (líder de limpieza u Operación) -----------------------
-- Cancelar: reserva cancelada, cambio de planes... Solo si aún no ha empezado (o no pudo entrar)
create or replace function public.cancelar_limpieza(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación cancelan limpiezas.'; end if;
  select * into v from public.limpiezas where id = p_id for update;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if v.estado::text not in ('sin_asignar', 'asignada', 'no_pude_entrar') then
    raise exception 'Solo se cancela una limpieza que no ha empezado (o en la que no se pudo entrar).';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escribe el motivo.'; end if;
  update public.limpiezas set estado = 'cancelada'::text::public.estado_limpieza, cancelada_motivo = left(btrim(p_motivo), 200)
   where id = p_id;
  perform public._evento('cancelada: ' || left(btrim(p_motivo), 200), p_id, null);
end $$;

-- Reabrir tras "no pude entrar": vuelve a la lista del mismo cleaner (el líder puede reasignarla luego)
create or replace function public.reabrir_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación reabren limpiezas.'; end if;
  select * into v from public.limpiezas where id = p_id for update;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if v.estado <> 'no_pude_entrar' then raise exception 'Solo se reabre una limpieza en la que no se pudo entrar.'; end if;
  update public.limpiezas set estado = 'asignada', inicio = null, fin = null, inicio_qr = null, gps = null,
         motivo_no_entrar = null, reabierta_en = now()
   where id = p_id;
  perform public._evento('reabierta (antes: ' || coalesce(v.motivo_no_entrar, '') || ')', p_id, null);
end $$;

-- 5. El driver no pudo entregar o recoger --------------------------------------------
create or replace function public.no_pude_entregar(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and public.mi_zona() = v.zona)) then
    raise exception 'Solo el driver de la zona puede marcarlo.';
  end if;
  if not ((v.tipo::text in ('linens', 'utiles') and v.estado = 'preparado') or (v.tipo = 'recogida' and v.estado = 'abierto')) then
    raise exception 'Ese pendiente no está en manos del driver.';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Write the reason.'; end if;
  update public.pendientes set incidencia = left(btrim(p_motivo), 200), incidencia_en = now() where id = p_id;
  perform public._evento('no se pudo entregar: ' || left(btrim(p_motivo), 200), v.limpieza_id, p_id);
end $$;

-- El líder de drivers lo resuelve: vuelve a la ruta como normal (el driver lo intenta de nuevo)
create or replace function public.resolver_incidencia(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo el líder de drivers u Operación.';
  end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or v.incidencia is null then raise exception 'Ese pendiente no tiene incidencia.'; end if;
  update public.pendientes set incidencia = null, incidencia_en = null where id = p_id;
  perform public._evento('incidencia resuelta: ' || v.incidencia, v.limpieza_id, p_id);
end $$;


-- Pantallas del cleaner y del driver: sin canceladas; el driver ve su incidencia
create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden, 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar, 'linens_revisado', l.linens_revisado,
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado, 'items', pe.items) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and l.asignada_a = (select auth.uid()) and l.estado::text <> 'cancelada'
      and public.mi_nivel() is not null
  ) t
$$;

create or replace function public.mi_ruta(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_zona public.zona := public.mi_zona();
begin
  if not (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers') then
    raise exception 'Esta pantalla es para drivers.';
  end if;
  return jsonb_build_object(
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'estado', pe.estado,
        'prioritario', pe.prioritario, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'foto', pe.foto, 'items', pe.items, 'incidencia', pe.incidencia)
        order by pe.prioritario desc, pe.creado_en)
      from public.pendientes pe
      join public.limpiezas l on l.id = pe.limpieza_id
      join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.fecha = p_fecha and pe.zona = v_zona
        and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto'))), '[]'::jsonb),
    'orden', coalesce((select jsonb_agg(jsonb_build_object(
        'cleaner', pf.nombre, 'orden', l.orden, 'estado', l.estado, 'codigo', p.codigo, 'nombre', p.nombre,
        'pueblo', p.pueblo, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by pf.nombre, l.orden)
      from public.limpiezas l
      join public.propiedades p on p.id = l.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      join public.perfiles pf on pf.id = l.asignada_a
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada and l.estado::text <> 'cancelada'), '[]'::jsonb));
end $$;

-- 6. Zona horaria de Malta en los tiempos -----------------------------------------
create or replace function public.tiempos_aptos(p_dias int default 90)
returns table (codigo text, nombre text, tipo text, limpiezas bigint, media_min int, mediana_min int, ultima date)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación.'; end if;
  return query
  select p.codigo, p.nombre, l.tipo::text, count(*),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60))::int,
         round(percentile_cont(0.5) within group (order by extract(epoch from (l.fin - l.inicio)) / 60))::int,
         max(l.fecha)
  from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
  where l.estado = 'terminada' and l.inicio_qr and l.fin_qr and l.fin is not null and l.inicio is not null
    and l.fecha >= (now() at time zone 'Europe/Malta')::date - p_dias
    and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'
  group by p.codigo, p.nombre, l.tipo
  order by p.codigo, l.tipo::text;
end $$;

create or replace function public.tiempos_personas(p_dias int default 90)
returns table (cleaner text, tipo text, limpiezas bigint, media_min int, sin_qr bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  return query
  select pf.nombre, l.tipo::text,
         count(*) filter (where l.inicio_qr and l.fin_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60)
               filter (where l.inicio_qr and l.fin_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'))::int,
         count(*) filter (where l.inicio_qr is false or l.fin_qr is false)
  from public.limpiezas l join public.perfiles pf on pf.id = l.asignada_a
  where l.estado = 'terminada' and l.fecha >= (now() at time zone 'Europe/Malta')::date - p_dias
  group by pf.nombre, l.tipo
  order by pf.nombre, l.tipo::text;
end $$;

-- 7. Avisos: no se pudo entregar → lider de drivers; cancelada / reabierta → cleaner --------
create or replace function public.avisos_para(p_tipo text, p_id uuid default null, p_fecha date default null)
returns table (perfil_id uuid, titulo text, cuerpo text, url text, clave text, telefonos jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  pe public.pendientes; li public.limpiezas; pr public.propiedades; ck public.checkouts;
  v_aviso text; v_ok boolean := true;
begin
  create temp table if not exists _dest (perfil_id uuid, idioma text, t_es text, t_en text, c_es text, c_en text, url text, clave text) on commit drop;
  truncate _dest;

  if p_tipo = 'pendiente' then
    select * into pe from public.pendientes where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = pe.propiedad_id;
    select c.* into ck from public.checkouts c join public.limpiezas l on l.checkout_id = c.id where l.id = pe.limpieza_id;
    v_aviso := 'pendiente:' || pe.id || ':' || pe.estado;

    if pe.incidencia is not null and pe.incidencia_en > now() - interval '2 minutes'
       and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto')) then
      -- 11. El driver no pudo entregar/recoger → lider de drivers
      insert into _dest select p.id, p.idioma,
        'No se pudo entregar: ' || pr.codigo, 'Couldn''t deliver: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.incidencia, pr.pueblo || ' · ' || pe.incidencia,
        './?v=drivers', 'pendiente:' || pe.id || ':incidencia:' || extract(epoch from pe.incidencia_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Drivers'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Deliver: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.foto is not null then
      -- 4b. Basura dejada en el apto (con foto) → drivers de la zona y lider de drivers
      insert into _dest select p.id, p.idioma,
        'Basura en el apto: ' || pr.codigo, 'Trash left: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.detalle, pr.pueblo || ' · pick it up (photo in the app)',
        './', null
      from public.perfiles p where p.activo and p.departamento = 'Drivers'
        and ((p.nivel = 'operador' and p.zona = pe.zona) or (p.nivel = 'lider' and (p.zona is null or p.zona = pe.zona)));

    elsif pe.tipo::text = 'utiles' and pe.estado = 'abierto' then
      -- 8. Faltan utiles → lider de bodega
      insert into _dest select p.id, p.idioma,
        'Útiles: ' || pe.detalle, 'Tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=bodega', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Bodega'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo::text = 'utiles' and pe.estado = 'preparado' then
      -- 9. Utiles preparados → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar útiles: ' || pe.detalle, 'Deliver tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' then
      -- 4. Recogida → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Recoger: basura y linens sucios', 'Pick up: trash & dirty linens',
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'linens' and pe.estado = 'entregado' then
      -- 5. Entregado → el cleaner que lo pidio
      insert into _dest select p.id, p.idioma,
        'Entregado: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Delivered: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=seguimiento', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en where true;  -- Supabase exige WHERE en todo UPDATE
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    if li.estado = 'terminada' and li.cierre->>'llaves' = 'false' then
      -- 10. Llaves NO dejadas en el key box → lider de limpieza y lider de drivers (urgente)
      insert into _dest select p.id, p.idioma,
        '⚠ Llaves NO en el key box: ' || pr.codigo, '⚠ Keys NOT in the key box: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''), pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''),
        case when p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, 'limpieza:' || li.id || ':llaves:' || p.id
      from public.perfiles p
      where p.activo and p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona);
      v_aviso := 'limpieza:' || li.id || ':llaves';
    elsif li.estado::text = 'cancelada' and li.publicada then
      -- 12. Limpieza cancelada → su cleaner
      insert into _dest select p.id, p.idioma,
        'Cancelada: ' || pr.codigo, 'Cancelled: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''), pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''),
        './', 'limpieza:' || li.id || ':cancelada:' || p.id
      from public.perfiles p where p.activo and p.id = li.asignada_a;
      v_aviso := 'limpieza:' || li.id || ':cancelada';
    elsif li.estado = 'asignada' and li.publicada and li.reabierta_en > now() - interval '2 minutes' then
      -- 13. Limpieza reabierta (tras "no pude entrar") → su cleaner
      insert into _dest select p.id, p.idioma,
        'Reabierta: ' || pr.codigo, 'Reopened: ' || pr.codigo,
        pr.pueblo || ' · vuelve a tu lista', pr.pueblo || ' · back on your list',
        './', 'limpieza:' || li.id || ':reabierta:' || extract(epoch from li.reabierta_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = li.asignada_a;
      v_aviso := 'limpieza:' || li.id || ':reabierta';
    elsif li.estado <> 'no_pude_entrar' then
      return;
    else
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));
    end if;

  elsif p_tipo = 'orden' then
    if p_fecha is null then return; end if;
    -- 1. Orden publicado → cada cleaner con limpiezas publicadas ese dia
    --    (la clave lleva cuantas tiene: si el lider le anade otra y publica, le vuelve a sonar)
    insert into _dest select p.id, p.idioma,
      'Orden de limpieza listo', 'Your cleaning order is ready',
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartamento' || case when count(*) > 1 then 's' else '' end,
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartment' || case when count(*) > 1 then 's' else '' end,
      './', 'orden:' || p_fecha || ':' || p.id || ':' || count(*)
    from public.limpiezas l join public.perfiles p on p.id = l.asignada_a
    where l.fecha = p_fecha and l.publicada and p.activo
    group by p.id, p.idioma;

  else
    return;
  end if;

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id) where true;

  -- Apuntar los nuevos; los que ya estaban apuntados no salen otra vez
  return query
  with nuevos as (
    insert into public.avisos_enviados (clave, perfil_id, titulo)
    select d.clave, d.perfil_id, case when d.idioma = 'es' then d.t_es else d.t_en end from _dest d
    on conflict (clave) do nothing
    returning avisos_enviados.clave
  )
  select d.perfil_id,
         case when d.idioma = 'es' then d.t_es else d.t_en end,
         case when d.idioma = 'es' then d.c_es else d.c_en end,
         d.url, d.clave,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                   from public.suscripciones s where s.perfil_id = d.perfil_id), '[]'::jsonb)
  from _dest d join nuevos n on n.clave = d.clave;
end $$;

-- 8. Historial de una limpieza (líder de limpieza u Operación) -----------------------
create or replace function public.historial(p_limpieza uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('en', e.cuando, 'que', e.que, 'quien', coalesce(p.nombre, '—')) order by e.cuando, e.id)
                   from public.eventos e left join public.perfiles p on p.id = e.quien
                   where e.limpieza_id = p_limpieza), '[]'::jsonb);
end $$;

-- 9. Informe del piloto (solo Operación): lo que mide si el piloto funciona ----------------
create or replace function public.informe(p_desde date, p_hasta date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 366 then
    raise exception 'Periodo no válido (máximo un año).';
  end if;
  return jsonb_build_object(
    'limpiezas', (select jsonb_build_object(
        'total', count(*),
        'terminadas', count(*) filter (where l.estado = 'terminada'),
        'canceladas', count(*) filter (where l.estado::text = 'cancelada'),
        'no_pudo_entrar', count(*) filter (where l.estado = 'no_pude_entrar'),
        'qr_ambos', count(*) filter (where l.estado = 'terminada' and l.inicio_qr and l.fin_qr),
        'sin_qr', count(*) filter (where l.estado = 'terminada' and (l.inicio_qr is not true or l.fin_qr is not true)),
        'gps_lejos', count(*) filter (where (l.gps->'inicio'->>'dist')::int > 200 or (l.gps->'fin'->>'dist')::int > 200),
        'sin_gps', count(*) filter (where l.estado = 'terminada' and ((l.gps->'inicio'->>'sin_gps')::boolean or (l.gps->'fin'->>'sin_gps')::boolean)),
        'linens_revisados', count(*) filter (where l.estado = 'terminada' and l.linens_revisado is not null),
        'llaves_no', count(*) filter (where l.cierre->>'llaves' = 'false'),
        'basura', count(*) filter (where l.cierre->>'basura' = 'true'),
        'media_min', round(avg(extract(epoch from l.fin - l.inicio) / 60) filter (
                       where l.estado = 'terminada' and l.inicio_qr and l.fin_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours')))
      from public.limpiezas l where l.fecha between p_desde and p_hasta),
    'pendientes', (select coalesce(jsonb_object_agg(t.tipo, t.datos), '{}'::jsonb) from (
        select pe.tipo::text as tipo, jsonb_build_object(
          'total', count(*), 'cerrados', count(*) filter (where pe.estado = 'cerrado'),
          'abiertos', count(*) filter (where pe.estado <> 'cerrado'),
          'abiertos_24h', count(*) filter (where pe.estado <> 'cerrado' and pe.creado_en < now() - interval '24 hours'),
          'incidencias', count(*) filter (where pe.incidencia is not null),
          'minutos_cierre', round(avg(extract(epoch from pe.cerrado_en - pe.creado_en) / 60) filter (where pe.estado = 'cerrado'))) as datos
        from public.pendientes pe where pe.fecha between p_desde and p_hasta group by pe.tipo) t),
    'articulos', (select coalesce(jsonb_agg(jsonb_build_object('item', a.item, 'cantidad', a.n) order by a.n desc), '[]'::jsonb) from (
        select x->>'item' as item, sum((x->>'cantidad')::int) as n
        from public.pendientes pe, jsonb_array_elements(pe.items) x
        where pe.fecha between p_desde and p_hasta and pe.items is not null group by x->>'item') a),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('fecha', d.fecha, 'terminadas', d.terminadas, 'pendientes', d.pendientes, 'cerrados', d.cerrados) order by d.fecha), '[]'::jsonb) from (
        select f.fecha,
               (select count(*) from public.limpiezas l where l.fecha = f.fecha and l.estado = 'terminada') as terminadas,
               (select count(*) from public.pendientes pe where pe.fecha = f.fecha) as pendientes,
               (select count(*) from public.pendientes pe where pe.fecha = f.fecha and pe.estado = 'cerrado') as cerrados
        from generate_series(p_desde, p_hasta, interval '1 day') g, lateral (select g::date as fecha) f) d
        where d.terminadas + d.pendientes > 0));
end $$;

-- 10. Permisos -----------------------------------------------------------------------
revoke execute on function
  public.iniciar_con_qr(uuid, text, double precision, double precision, double precision),
  public.iniciar_limpieza(uuid, double precision, double precision, double precision),
  public.cerrar_limpieza(uuid, text, boolean, boolean, boolean, boolean, boolean, text, double precision, double precision, double precision),
  public.cancelar_limpieza(uuid, text), public.reabrir_limpieza(uuid), public.no_pude_entregar(uuid, text),
  public.resolver_incidencia(uuid), public.historial(uuid), public.informe(date, date)
from public, anon;
grant execute on function
  public.iniciar_con_qr(uuid, text, double precision, double precision, double precision),
  public.iniciar_limpieza(uuid, double precision, double precision, double precision),
  public.cerrar_limpieza(uuid, text, boolean, boolean, boolean, boolean, boolean, text, double precision, double precision, double precision),
  public.cancelar_limpieza(uuid, text), public.reabrir_limpieza(uuid), public.no_pude_entregar(uuid, text),
  public.resolver_incidencia(uuid), public.historial(uuid), public.informe(date, date)
to authenticated;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;


-- ═══════════════ 20-PEGAR-arreglo_checklist.sql ═══════════════
-- OpsFlow · arreglo: la checklist no se abría después de revisar los linens (10 oct 2026)
-- Causa: el archivo 13 se pegó después del 15 y dejó dos funciones en su versión antigua
-- (mi_checklist no decía que los linens ya estaban revisados, y registrar_foto no pedía la revisión).
-- Esto las devuelve a su versión buena. Se puede ejecutar varias veces y no borra datos.

create or replace function public.mi_checklist(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id;
  if not found or public.mi_nivel() is null
     or not (public._lider_limpieza() or (v.asignada_a = (select auth.uid()) and v.publicada)) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return jsonb_build_object(
    'inicio_qr', v.inicio_qr, 'fin_qr', v.fin_qr, 'linens_revisado', v.linens_revisado, 'cierre', v.cierre, 'personas', v.personas, 'estado', v.estado,
    'pasos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sala', p.sala, 'en', p.texto_en, 'es', p.texto_es,
                          'obligatorio', p.obligatorio, 'hecho', v.checklist ? p.id::text) order by p.orden)
                       from public.checklist_pasos p where p.tipo = v.tipo and p.activo), '[]'::jsonb),
    'fotos', coalesce((select jsonb_object_agg(f.sala, f.ruta) from public.fotos_cierre f where f.limpieza_id = p_id), '{}'::jsonb));
end $$;

create or replace function public.registrar_foto(p_id uuid, p_sala text, p_ruta text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  if p_sala not in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura') then raise exception 'Sala no válida.'; end if;
  if split_part(p_ruta, '/', 1) <> p_id::text then raise exception 'La foto no es de esta limpieza.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por)
  values (p_id, p_sala, p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
end $$;

-- Comprobación: las dos filas deben decir true
select p.proname, (p.prosrc like '%linens_revisado%' or p.prosrc like '%Check the linens%') as arreglada
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('mi_checklist', 'registrar_foto') order by 1;


-- ═══════════════ 21-PEGAR-tablero_bolsas.sql ═══════════════
-- OpsFlow · tablero de zonas para drivers + bolsas de linens con QR (10 oct 2026)
-- Todos los drivers ven lo pendiente de Norte / Centro / Sur, cogen tareas ("I'll take it") y el líder asigna.
-- Cada limpieza tiene su bolsa de linens: linens la prepara (etiqueta QR) → el driver la escanea → la entrega con foto.
-- Ejecutar DESPUES de 020. Se puede ejecutar varias veces. Todo UPDATE/DELETE lleva WHERE.

-- 1. Quién lleva cada tarea --------------------------------------------------------
alter table public.pendientes add column if not exists tomado_por uuid references public.perfiles(id);
alter table public.pendientes add column if not exists tomado_en timestamptz;
alter table public.pendientes add column if not exists asignado_por uuid;     -- si lo asignó el líder

-- Todos los drivers ven lo que está en manos de los drivers en TODAS las zonas (antes, solo la suya)
drop policy if exists "pendientes: lectura por rol" on public.pendientes;
create policy "pendientes: lectura por rol" on public.pendientes for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Linens' and tipo::text = 'linens')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Bodega' and tipo::text = 'utiles')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Drivers' and tipo::text in ('linens', 'recogida', 'utiles'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and limpieza_id in (select id from public.limpiezas where asignada_a = (select auth.uid())))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and (tipo::text = 'recogida' or (tipo::text in ('linens', 'utiles') and estado <> 'abierto')))
);

-- ¿Puede quien llama trabajar como driver? (driver, líder de drivers u Operación)
create or replace function public._es_driver()
returns boolean language sql stable security definer set search_path = ''
as $$ select public.mi_departamento() = 'Drivers' or public.mi_nivel() = 'operacion' $$;
revoke execute on function public._es_driver() from public, anon, authenticated;

-- ¿Está esta tarea en manos de los drivers?
create or replace function public._en_driver(v public.pendientes)
returns boolean language sql immutable set search_path = ''
as $$ select (v.tipo::text in ('linens', 'utiles') and v.estado::text = 'preparado') or (v.tipo::text = 'recogida' and v.estado::text = 'abierto') $$;
revoke execute on function public._en_driver(public.pendientes) from public, anon, authenticated;

-- 2. Tablero de zonas: todo lo pendiente para drivers (últimos 7 días), check-in de hoy primero ----
create or replace function public.tablero_zonas()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'zona', (x->>'prioridad')::int desc, x->>'entrada' nulls last, x->>'desde') from (
    select jsonb_build_object(
      'id', pe.id, 'zona', pe.zona, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'items', pe.items,
      'foto', pe.foto, 'incidencia', pe.incidencia, 'fecha', pe.fecha,
      'desde', coalesce(pe.preparado_en, pe.creado_en),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end,
      'prioridad', case when c.fecha = v_hoy and c.hora_entrada is not null then 1 else 0 end,
      'tomado_por', t.nombre, 'mio', pe.tomado_por = (select auth.uid()), 'asignado', pe.asignado_por is not null) as x
    from public.pendientes pe
    join public.propiedades p on p.id = pe.propiedad_id
    join public.limpiezas l on l.id = pe.limpieza_id
    join public.checkouts c on c.id = l.checkout_id
    left join public.perfiles t on t.id = pe.tomado_por
    where public._en_driver(pe) and pe.fecha >= v_hoy - 7) s), '[]'::jsonb);
end $$;

-- 3. Coger, soltar y asignar --------------------------------------------------------------
create or replace function public.tomar_tarea(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes; v_quien text;
begin
  if not (public.mi_departamento() = 'Drivers' and public.mi_nivel() = 'operador') then raise exception 'Only drivers take jobs.'; end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or not public._en_driver(v) then raise exception 'This job is not waiting for a driver.'; end if;
  if v.tomado_por is not null and v.tomado_por <> (select auth.uid()) then
    select nombre into v_quien from public.perfiles where id = v.tomado_por;
    raise exception '% is already on it.', v_quien;
  end if;
  update public.pendientes set tomado_por = (select auth.uid()), tomado_en = now(), asignado_por = null where id = p_id;
  perform public._evento('tarea cogida por driver', v.limpieza_id, p_id);
end $$;

create or replace function public.soltar_tarea(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  if v.tomado_por is distinct from (select auth.uid())
     and not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Only the driver who took it (or the leader) can release it.';
  end if;
  update public.pendientes set tomado_por = null, tomado_en = null, asignado_por = null where id = p_id;
  perform public._evento('tarea soltada', v.limpieza_id, p_id);
end $$;

create or replace function public.asignar_tarea(p_id uuid, p_driver uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo el líder de drivers u Operación asignan.';
  end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or not public._en_driver(v) then raise exception 'Ese pendiente no está esperando a un driver.'; end if;
  if not exists (select 1 from public.perfiles where id = p_driver and activo and departamento = 'Drivers' and nivel = 'operador') then
    raise exception 'Solo se asigna a un driver activo.';
  end if;
  update public.pendientes set tomado_por = p_driver, tomado_en = now(), asignado_por = (select auth.uid()) where id = p_id;
  perform public._evento('asignada a driver por el líder', v.limpieza_id, p_id);
end $$;

-- 4. Bolsas de linens con QR ---------------------------------------------------------------
create table if not exists public.bolsas (
  id           uuid primary key default gen_random_uuid(),
  limpieza_id  uuid not null unique references public.limpiezas(id) on delete cascade,
  propiedad_id uuid not null references public.propiedades(id),
  zona         public.zona not null,
  fecha        date not null,
  token        text not null unique default replace(gen_random_uuid()::text, '-', ''),
  estado       text not null default 'por_preparar' check (estado in ('por_preparar', 'preparada', 'en_camion', 'entregada')),
  preparada_por uuid, preparada_en timestamptz,
  driver       uuid references public.perfiles(id), recogida_en timestamptz,
  entregada_en timestamptz, comentario text check (length(comentario) <= 300),
  incidencia   text, incidencia_en timestamptz,
  es_prueba    boolean not null default false
);
alter table public.bolsas enable row level security;
revoke all on public.bolsas from anon;
revoke insert, update, delete, truncate on public.bolsas from authenticated;
revoke select (token) on public.bolsas from authenticated;
drop policy if exists "bolsas: lectura" on public.bolsas;
create policy "bolsas: lectura" on public.bolsas for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) in ('Linens', 'Drivers', 'Limpieza'))
  or ((select public.mi_departamento()) = 'Drivers' and (select public.mi_nivel()) = 'operador')
  or limpieza_id in (select id from public.limpiezas where asignada_a = (select auth.uid()))
);
-- El token (lo que lleva el QR) no se lee de la tabla: solo linens lo imprime
do $$ begin
  revoke select on public.bolsas from authenticated;
  grant select (id, limpieza_id, propiedad_id, zona, fecha, estado, preparada_por, preparada_en, driver, recogida_en,
                entregada_en, comentario, incidencia, incidencia_en, es_prueba) on public.bolsas to authenticated;
end $$;

-- La foto de entrega se guarda como una "sala" más de la limpieza: <limpieza>/bolsa.jpg (se borra a los 30 días)
do $$ declare c text; begin
  for c in select conname from pg_constraint
           where conrelid = 'public.fotos_cierre'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%sala%'
  loop execute format('alter table public.fotos_cierre drop constraint %I', c); end loop;
end $$;
alter table public.fotos_cierre add constraint fotos_cierre_sala_check
  check (sala in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura', 'bolsa'));

-- Subir foto: el cleaner (su limpieza en curso) o el driver que lleva esa bolsa (solo bolsa.jpg)
create or replace function public._puede_subir_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and l.asignada_a = (select auth.uid()) and l.publicada and l.estado = 'en_curso'
      and public.mi_nivel() is not null)
  or (split_part(p_nombre, '/', 2) = 'bolsa.jpg' and exists (
    select 1 from public.bolsas b
    where b.limpieza_id::text = split_part(p_nombre, '/', 1) and b.driver = (select auth.uid()) and b.estado = 'en_camion'))
$$;
-- Ver fotos: como antes + la de la bolsa la ven linens, drivers y el cleaner de esa limpieza
create or replace function public._puede_ver_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select public._lider_limpieza()
  or exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1) and l.asignada_a = (select auth.uid()) and public.mi_nivel() is not null)
  or (split_part(p_nombre, '/', 2) = 'basura.jpg' and public.mi_departamento() = 'Drivers' and exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and (public.mi_nivel() = 'lider' or l.zona = public.mi_zona())))
  or (split_part(p_nombre, '/', 2) = 'bolsa.jpg' and (public.mi_departamento() in ('Drivers', 'Linens')))
$$;
revoke execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) from public, anon;
grant  execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) to authenticated;

-- Bolsas de un día (se crean solas para cada limpieza no cancelada). Linens, líderes de drivers/limpieza y Operación.
create or replace function public.bolsas_dia(p_fecha date)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() in ('Linens', 'Drivers', 'Limpieza'))) then
    raise exception 'Solo linens, los líderes u Operación.';
  end if;
  insert into public.bolsas (limpieza_id, propiedad_id, zona, fecha, es_prueba)
  select l.id, l.propiedad_id, l.zona, l.fecha, l.es_prueba from public.limpiezas l
  where l.fecha = p_fecha and l.estado::text <> 'cancelada'
  on conflict (limpieza_id) do nothing;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', b.id, 'estado', b.estado, 'zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
      'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'salida', to_char(c.hora_salida, 'HH24:MI'),
      'cancelada', l.estado::text = 'cancelada', 'driver', d.nombre, 'recogida_en', b.recogida_en, 'entregada_en', b.entregada_en,
      'comentario', b.comentario, 'incidencia', b.incidencia,
      'foto', (select f.ruta from public.fotos_cierre f where f.limpieza_id = b.limpieza_id and f.sala = 'bolsa'))
      order by (c.hora_entrada is not null) desc, c.hora_entrada, p.codigo)
    from public.bolsas b join public.limpiezas l on l.id = b.limpieza_id join public.propiedades p on p.id = b.propiedad_id
    join public.checkouts c on c.id = l.checkout_id left join public.perfiles d on d.id = b.driver
    where b.fecha = p_fecha), '[]'::jsonb);
end $$;

-- Linens: bolsa preparada (y deshacer si se equivocó, mientras no la haya cogido un driver)
create or replace function public.preparar_bolsa(p_bolsa uuid, p_lista boolean default true)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas;
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Linens')) then
    raise exception 'Solo linens u Operación preparan bolsas.';
  end if;
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found then raise exception 'Esa bolsa no existe.'; end if;
  if v.estado not in ('por_preparar', 'preparada') then raise exception 'Esa bolsa ya la tiene un driver.'; end if;
  if exists (select 1 from public.limpiezas where id = v.limpieza_id and estado::text = 'cancelada') then raise exception 'Esa limpieza está cancelada.'; end if;
  update public.bolsas set estado = case when p_lista then 'preparada' else 'por_preparar' end,
         preparada_por = case when p_lista then (select auth.uid()) end, preparada_en = case when p_lista then now() end
   where id = p_bolsa;
  perform public._evento(case when p_lista then 'bolsa preparada' else 'bolsa vuelve a por preparar' end, v.limpieza_id, null);
end $$;

-- Etiquetas para imprimir (con el código del QR): solo linens y Operación
create or replace function public.bolsas_etiquetas(p_fecha date)
returns table (codigo text, nombre text, fecha date, zona text, qr text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Linens')) then
    raise exception 'Solo linens u Operación.';
  end if;
  return query select p.codigo, p.nombre, b.fecha, b.zona::text, 'OPSFLOW-BAG:' || b.token
    from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
    where b.fecha = p_fecha and l.estado::text <> 'cancelada' order by p.codigo;
end $$;

-- Driver: escanear la etiqueta → la bolsa pasa a SU lista
create or replace function public.escanear_bolsa(p_qr text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas; v_quien text; v_cod text;
begin
  if not (public.mi_departamento() = 'Drivers' and public.mi_nivel() = 'operador') then raise exception 'Only drivers scan bags.'; end if;
  select * into v from public.bolsas where token = regexp_replace(btrim(coalesce(p_qr, '')), '^OPSFLOW-BAG:', '') for update;
  if not found then raise exception 'This is not an OpsFlow bag label.'; end if;
  select codigo into v_cod from public.propiedades where id = v.propiedad_id;
  if exists (select 1 from public.limpiezas where id = v.limpieza_id and estado::text = 'cancelada') then raise exception 'Cleaning cancelled: leave the bag % at linens.', v_cod; end if;
  if v.estado = 'por_preparar' then raise exception 'Bag % is not ready yet (linens has not marked it).', v_cod; end if;
  if v.estado = 'entregada' then raise exception 'Bag % was already delivered.', v_cod; end if;
  if v.estado = 'en_camion' and v.driver <> (select auth.uid()) then
    select nombre into v_quien from public.perfiles where id = v.driver;
    raise exception 'Bag % is already with %.', v_cod, v_quien;
  end if;
  update public.bolsas set estado = 'en_camion', driver = (select auth.uid()), recogida_en = coalesce(recogida_en, now()) where id = v.id;
  perform public._evento('bolsa recogida en linens', v.limpieza_id, null);
  return jsonb_build_object('id', v.id, 'codigo', v_cod);
end $$;

-- Driver: entregada, con foto (obligatoria, ya subida a <limpieza>/bolsa.jpg) y comentario opcional
create or replace function public.entregar_bolsa(p_bolsa uuid, p_ruta text, p_comentario text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas;
begin
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found or v.driver is distinct from (select auth.uid()) or v.estado <> 'en_camion' then
    raise exception 'This bag is not on your list.';
  end if;
  if p_ruta is distinct from v.limpieza_id || '/bolsa.jpg' then raise exception 'Take the delivery photo first.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por) values (v.limpieza_id, 'bolsa', p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
  update public.bolsas set estado = 'entregada', entregada_en = now(), comentario = nullif(left(btrim(coalesce(p_comentario, '')), 300), ''),
         incidencia = null, incidencia_en = null where id = p_bolsa;
  perform public._evento('bolsa entregada' || coalesce(': ' || nullif(btrim(coalesce(p_comentario, '')), ''), ''), v.limpieza_id, null);
end $$;

-- Driver: no pudo entregar la bolsa (sigue en su lista; el líder lo ve)
create or replace function public.no_pude_entregar_bolsa(p_bolsa uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas;
begin
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found or v.driver is distinct from (select auth.uid()) or v.estado <> 'en_camion' then raise exception 'This bag is not on your list.'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Write the reason.'; end if;
  update public.bolsas set incidencia = left(btrim(p_motivo), 200), incidencia_en = now() where id = p_bolsa;
  perform public._evento('bolsa no entregada: ' || left(btrim(p_motivo), 200), v.limpieza_id, null);
end $$;

-- Lista del driver: sus bolsas y sus tareas cogidas
create or replace function public.mis_trabajos()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return jsonb_build_object(
    'bolsas', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'limpieza_id', b.limpieza_id, 'zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'incidencia', b.incidencia,
        'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end)
        order by (c.fecha = v_hoy and c.hora_entrada is not null) desc, c.hora_entrada, p.codigo)
      from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
      join public.checkouts c on c.id = l.checkout_id
      where b.driver = (select auth.uid()) and b.estado = 'en_camion'), '[]'::jsonb));
end $$;

-- 5. Entregar y "no pude": quien cogió la tarea (aunque sea de otra zona); si nadie, el driver de la zona ----
create or replace function public.marcar_entregado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  -- Lo hace quien la cogió; si nadie la cogió, cualquier driver de esa zona; siempre el líder u Operación
  if v.tomado_por is not null and v.tomado_por <> (select auth.uid())
     and not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Another driver is on this job.';
  end if;
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and (public.mi_zona() = v.zona or coalesce(v.tomado_por = (select auth.uid()), false)))) then
    raise exception 'Solo el driver de la zona puede marcar la entrega.';
  end if;
  if v.tipo = 'linens' and v.estado = 'preparado' then
    update public.pendientes set estado = 'entregado', entregado_por = (select auth.uid()), entregado_en = now() where id = p_id;
    perform public._evento('entregado por driver', v.limpieza_id, p_id);
  elsif v.tipo::text = 'utiles' and v.estado = 'preparado' then
    -- Utiles: el driver los deja en el apto y queda cerrado (no hay nadie que marque recibido)
    update public.pendientes set estado = 'cerrado', entregado_por = (select auth.uid()), entregado_en = now(),
                                 cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
    perform public._evento('útiles entregados por driver', v.limpieza_id, p_id);
  elsif v.tipo = 'recogida' and v.estado = 'abierto' then
    update public.pendientes set estado = 'cerrado', entregado_por = (select auth.uid()), entregado_en = now(),
                                 cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
    perform public._evento('recogido por driver', v.limpieza_id, p_id);
  else
    raise exception 'Ese pendiente todavía no está listo para el driver.';
  end if;
end $$;

create or replace function public.no_pude_entregar(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  -- Lo hace quien la cogió; si nadie la cogió, cualquier driver de esa zona; siempre el líder u Operación
  if v.tomado_por is not null and v.tomado_por <> (select auth.uid())
     and not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Another driver is on this job.';
  end if;
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and (public.mi_zona() = v.zona or coalesce(v.tomado_por = (select auth.uid()), false)))) then
    raise exception 'Solo el driver de la zona puede marcarlo.';
  end if;
  if not ((v.tipo::text in ('linens', 'utiles') and v.estado = 'preparado') or (v.tipo = 'recogida' and v.estado = 'abierto')) then
    raise exception 'Ese pendiente no está en manos del driver.';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Write the reason.'; end if;
  update public.pendientes set incidencia = left(btrim(p_motivo), 200), incidencia_en = now() where id = p_id;
  perform public._evento('no se pudo entregar: ' || left(btrim(p_motivo), 200), v.limpieza_id, p_id);
end $$;

-- 6. Pantallas: el driver ve primero los check-in de hoy; el cleaner ve su bolsa; avisos de asignación ----
create or replace function public.mi_ruta(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_zona public.zona := public.mi_zona();
begin
  if not (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers') then
    raise exception 'Esta pantalla es para drivers.';
  end if;
  return jsonb_build_object(
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'estado', pe.estado,
        'prioritario', pe.prioritario, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'foto', pe.foto, 'items', pe.items, 'incidencia', pe.incidencia)
        order by pe.prioritario desc, c.hora_entrada nulls last, pe.creado_en)
      from public.pendientes pe
      join public.limpiezas l on l.id = pe.limpieza_id
      join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.fecha = p_fecha and pe.zona = v_zona
        and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto'))), '[]'::jsonb),
    'orden', coalesce((select jsonb_agg(jsonb_build_object(
        'cleaner', pf.nombre, 'orden', l.orden, 'estado', l.estado, 'codigo', p.codigo, 'nombre', p.nombre,
        'pueblo', p.pueblo, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by pf.nombre, l.orden)
      from public.limpiezas l
      join public.propiedades p on p.id = l.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      join public.perfiles pf on pf.id = l.asignada_a
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada and l.estado::text <> 'cancelada'), '[]'::jsonb));
end $$;

create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden, 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar, 'linens_revisado', l.linens_revisado,
      'bolsa', (select jsonb_build_object('estado', b.estado, 'entregada_en', to_char(b.entregada_en at time zone 'Europe/Malta', 'HH24:MI'), 'comentario', b.comentario) from public.bolsas b where b.limpieza_id = l.id),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado, 'items', pe.items) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and l.asignada_a = (select auth.uid()) and l.estado::text <> 'cancelada'
      and public.mi_nivel() is not null
  ) t
$$;

create or replace function public.avisos_para(p_tipo text, p_id uuid default null, p_fecha date default null)
returns table (perfil_id uuid, titulo text, cuerpo text, url text, clave text, telefonos jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  pe public.pendientes; li public.limpiezas; pr public.propiedades; ck public.checkouts;
  v_aviso text; v_ok boolean := true;
begin
  create temp table if not exists _dest (perfil_id uuid, idioma text, t_es text, t_en text, c_es text, c_en text, url text, clave text) on commit drop;
  truncate _dest;

  if p_tipo = 'pendiente' then
    select * into pe from public.pendientes where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = pe.propiedad_id;
    select c.* into ck from public.checkouts c join public.limpiezas l on l.checkout_id = c.id where l.id = pe.limpieza_id;
    v_aviso := 'pendiente:' || pe.id || ':' || pe.estado;

    if pe.asignado_por is not null and pe.tomado_por is not null and pe.tomado_en > now() - interval '2 minutes' then
      -- 14. El líder asigna una tarea a un driver concreto → ese driver
      insert into _dest select p.id, p.idioma,
        'Asignado a ti: ' || pr.codigo, 'Assigned to you: ' || pr.codigo,
        pr.pueblo || ' · ' || case when pe.tipo = 'recogida' then 'recoger' else 'entregar' end,
        pr.pueblo || ' · ' || case when pe.tipo = 'recogida' then 'pick up' else 'deliver' end,
        './', 'pendiente:' || pe.id || ':asignado:' || extract(epoch from pe.tomado_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = pe.tomado_por;

    elsif pe.incidencia is not null and pe.incidencia_en > now() - interval '2 minutes'
       and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto')) then
      -- 11. El driver no pudo entregar/recoger → lider de drivers
      insert into _dest select p.id, p.idioma,
        'No se pudo entregar: ' || pr.codigo, 'Couldn''t deliver: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.incidencia, pr.pueblo || ' · ' || pe.incidencia,
        './?v=drivers', 'pendiente:' || pe.id || ':incidencia:' || extract(epoch from pe.incidencia_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Drivers'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Deliver: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.foto is not null then
      -- 4b. Basura dejada en el apto (con foto) → drivers de la zona y lider de drivers
      insert into _dest select p.id, p.idioma,
        'Basura en el apto: ' || pr.codigo, 'Trash left: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.detalle, pr.pueblo || ' · pick it up (photo in the app)',
        './', null
      from public.perfiles p where p.activo and p.departamento = 'Drivers'
        and ((p.nivel = 'operador' and p.zona = pe.zona) or (p.nivel = 'lider' and (p.zona is null or p.zona = pe.zona)));

    elsif pe.tipo::text = 'utiles' and pe.estado = 'abierto' then
      -- 8. Faltan utiles → lider de bodega
      insert into _dest select p.id, p.idioma,
        'Útiles: ' || pe.detalle, 'Tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=bodega', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Bodega'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo::text = 'utiles' and pe.estado = 'preparado' then
      -- 9. Utiles preparados → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar útiles: ' || pe.detalle, 'Deliver tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' then
      -- 4. Recogida → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Recoger: basura y linens sucios', 'Pick up: trash & dirty linens',
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'linens' and pe.estado = 'entregado' then
      -- 5. Entregado → el cleaner que lo pidio
      insert into _dest select p.id, p.idioma,
        'Entregado: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Delivered: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=seguimiento', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en where true;  -- Supabase exige WHERE en todo UPDATE
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    if li.estado = 'terminada' and li.cierre->>'llaves' = 'false' then
      -- 10. Llaves NO dejadas en el key box → lider de limpieza y lider de drivers (urgente)
      insert into _dest select p.id, p.idioma,
        '⚠ Llaves NO en el key box: ' || pr.codigo, '⚠ Keys NOT in the key box: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''), pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''),
        case when p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, 'limpieza:' || li.id || ':llaves:' || p.id
      from public.perfiles p
      where p.activo and p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona);
      v_aviso := 'limpieza:' || li.id || ':llaves';
    elsif li.estado::text = 'cancelada' and li.publicada then
      -- 12. Limpieza cancelada → su cleaner
      insert into _dest select p.id, p.idioma,
        'Cancelada: ' || pr.codigo, 'Cancelled: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''), pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''),
        './', 'limpieza:' || li.id || ':cancelada:' || p.id
      from public.perfiles p where p.activo and p.id = li.asignada_a;
      v_aviso := 'limpieza:' || li.id || ':cancelada';
    elsif li.estado = 'asignada' and li.publicada and li.reabierta_en > now() - interval '2 minutes' then
      -- 13. Limpieza reabierta (tras "no pude entrar") → su cleaner
      insert into _dest select p.id, p.idioma,
        'Reabierta: ' || pr.codigo, 'Reopened: ' || pr.codigo,
        pr.pueblo || ' · vuelve a tu lista', pr.pueblo || ' · back on your list',
        './', 'limpieza:' || li.id || ':reabierta:' || extract(epoch from li.reabierta_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = li.asignada_a;
      v_aviso := 'limpieza:' || li.id || ':reabierta';
    elsif li.estado <> 'no_pude_entrar' then
      return;
    else
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));
    end if;

  elsif p_tipo = 'orden' then
    if p_fecha is null then return; end if;
    -- 1. Orden publicado → cada cleaner con limpiezas publicadas ese dia
    --    (la clave lleva cuantas tiene: si el lider le anade otra y publica, le vuelve a sonar)
    insert into _dest select p.id, p.idioma,
      'Orden de limpieza listo', 'Your cleaning order is ready',
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartamento' || case when count(*) > 1 then 's' else '' end,
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartment' || case when count(*) > 1 then 's' else '' end,
      './', 'orden:' || p_fecha || ':' || p.id || ':' || count(*)
    from public.limpiezas l join public.perfiles p on p.id = l.asignada_a
    where l.fecha = p_fecha and l.publicada and p.activo
    group by p.id, p.idioma;

  else
    return;
  end if;

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id) where true;

  -- Apuntar los nuevos; los que ya estaban apuntados no salen otra vez
  return query
  with nuevos as (
    insert into public.avisos_enviados (clave, perfil_id, titulo)
    select d.clave, d.perfil_id, case when d.idioma = 'es' then d.t_es else d.t_en end from _dest d
    on conflict (clave) do nothing
    returning avisos_enviados.clave
  )
  select d.perfil_id,
         case when d.idioma = 'es' then d.t_es else d.t_en end,
         case when d.idioma = 'es' then d.c_es else d.c_en end,
         d.url, d.clave,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                   from public.suscripciones s where s.perfil_id = d.perfil_id), '[]'::jsonb)
  from _dest d join nuevos n on n.clave = d.clave;
end $$;

-- 7. Permisos -------------------------------------------------------------------------
revoke execute on function public.tablero_zonas(), public.tomar_tarea(uuid), public.soltar_tarea(uuid), public.asignar_tarea(uuid, uuid),
  public.bolsas_dia(date), public.preparar_bolsa(uuid, boolean), public.bolsas_etiquetas(date), public.escanear_bolsa(text),
  public.entregar_bolsa(uuid, text, text), public.no_pude_entregar_bolsa(uuid, text), public.mis_trabajos() from public, anon;
grant execute on function public.tablero_zonas(), public.tomar_tarea(uuid), public.soltar_tarea(uuid), public.asignar_tarea(uuid, uuid),
  public.bolsas_dia(date), public.preparar_bolsa(uuid, boolean), public.bolsas_etiquetas(date), public.escanear_bolsa(text),
  public.entregar_bolsa(uuid, text, text), public.no_pude_entregar_bolsa(uuid, text), public.mis_trabajos() to authenticated;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;


-- ═══════════════ 23-PEGAR-trafico.sql ═══════════════
-- OpsFlow · tráfico en tiempo real (TomTom) por zona (10 oct 2026)
-- La función "trafico" consulta TomTom cada 10 min y guarda aquí lo relevante; los teléfonos solo leen de aquí.
-- La clave de TomTom vive SOLO en los secretos de Supabase (TOMTOM_KEY). Se puede ejecutar varias veces.

-- 1. Incidencias actuales (se reemplazan en cada consulta) y estado de la última consulta -------------
create table if not exists public.trafico (
  id          text primary key,              -- id de TomTom
  tipo        int not null,                  -- iconCategory de TomTom (1 accidente, 6 atasco, 7 carril, 8 vía cerrada, 9 obras)
  gravedad    int not null default 0,        -- magnitudeOfDelay 0..4
  municipio   text,
  zona        text not null default 'General' check (zona in ('Norte', 'Centro', 'Sur', 'General')),
  desde_calle text, hasta_calle text,
  retraso_min int not null default 0,
  km          numeric(6,1) not null default 0,
  detalle     text,
  hasta       timestamptz,                   -- cuándo se espera que termine
  lat double precision, lng double precision,
  visto_en    timestamptz not null default now()
);
create table if not exists public.trafico_estado (
  id int primary key default 1 check (id = 1),
  actualizado_en timestamptz, error text
);
insert into public.trafico_estado (id) values (1) on conflict (id) do nothing;

alter table public.trafico enable row level security;
alter table public.trafico_estado enable row level security;
revoke all on public.trafico, public.trafico_estado from anon, authenticated;

-- 2. Zona de un pueblo: la de tus apartamentos en ese pueblo (la más frecuente); si no hay, General ---------
create or replace function public._zona_de_pueblo(p_pueblo text)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select p.zona::text from public.propiedades p
    where p.activa and lower(regexp_replace(p.pueblo, '[^[:alpha:]]', '', 'g'))
                     = lower(regexp_replace(coalesce(p_pueblo, ''), '[^[:alpha:]]', '', 'g'))
      and coalesce(p_pueblo, '') <> ''
    group by p.zona order by count(*) desc limit 1), 'General')
$$;
revoke execute on function public._zona_de_pueblo(text) from public, anon, authenticated;

-- 3. Guardar una consulta (solo el servidor): reemplaza todas las incidencias de golpe ---------------------
create or replace function public.trafico_guardar(p_incidencias jsonb, p_error text default null)
returns int language plpgsql security definer set search_path = ''
as $$
declare n int := 0;
begin
  if p_error is not null then
    update public.trafico_estado set error = left(p_error, 300) where id = 1;
    return 0;
  end if;
  delete from public.trafico where true;   -- Supabase exige WHERE
  insert into public.trafico (id, tipo, gravedad, municipio, zona, desde_calle, hasta_calle, retraso_min, km, detalle, hasta, lat, lng)
  select x->>'id', (x->>'tipo')::int, coalesce((x->>'gravedad')::int, 0), x->>'municipio', public._zona_de_pueblo(x->>'municipio'),
         left(x->>'desde', 120), left(x->>'hasta_calle', 120), coalesce((x->>'retraso_min')::int, 0), coalesce((x->>'km')::numeric, 0),
         left(x->>'detalle', 300), nullif(x->>'fin', '')::timestamptz, (x->>'lat')::double precision, (x->>'lng')::double precision
  from jsonb_array_elements(coalesce(p_incidencias, '[]'::jsonb)) x
  where x->>'id' is not null
  on conflict (id) do nothing;
  get diagnostics n = row_count;
  update public.trafico_estado set actualizado_en = now(), error = null where id = 1;
  return n;
end $$;
revoke execute on function public.trafico_guardar(jsonb, text) from public, anon, authenticated;
grant  execute on function public.trafico_guardar(jsonb, text) to service_role;

-- Municipios ya conocidos (para no volver a preguntar a TomTom por los mismos): solo el servidor
create or replace function public.trafico_conocidos()
returns table (id text, municipio text) language sql stable security definer set search_path = ''
as $$ select t.id, t.municipio from public.trafico t $$;
revoke execute on function public.trafico_conocidos() from public, anon, authenticated;
grant  execute on function public.trafico_conocidos() to service_role;

-- ¿Hace falta consultar TomTom? (si la última consulta tiene menos de 5 min, no: protege el cupo gratuito)
create or replace function public.trafico_toca()
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce((select actualizado_en from public.trafico_estado where id = 1) < now() - interval '5 minutes', true) $$;
revoke execute on function public.trafico_toca() from public, anon, authenticated;
grant  execute on function public.trafico_toca() to service_role;

-- 4. Lo que ve la app: drivers, líderes y Operación ---------------------------------------------------
create or replace function public.trafico_actual()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.mi_departamento() = 'Drivers' or public.mi_nivel() in ('lider', 'operacion')) then
    raise exception 'Solo drivers, líderes y Operación.';
  end if;
  return jsonb_build_object(
    'actualizado_en', (select actualizado_en from public.trafico_estado where id = 1),
    'error', (select error from public.trafico_estado where id = 1),
    'incidencias', coalesce((select jsonb_agg(jsonb_build_object(
        'tipo', t.tipo, 'gravedad', t.gravedad, 'municipio', t.municipio, 'zona', t.zona,
        'desde', t.desde_calle, 'hasta_calle', t.hasta_calle, 'retraso_min', t.retraso_min, 'km', t.km,
        'detalle', t.detalle, 'hasta', t.hasta)
        order by case t.tipo when 8 then 0 when 1 then 1 when 7 then 2 else 3 end, t.retraso_min desc)
      from public.trafico t), '[]'::jsonb));
end $$;
revoke execute on function public.trafico_actual() from public, anon;
grant  execute on function public.trafico_actual() to authenticated;

-- (apartado 5, tarea cron que llama a PRODUCCIÓN: omitido en el proyecto de pruebas)


-- ═══════════════ 25-PEGAR-ubicaciones.sql ═══════════════
-- OpsFlow · ubicaciones: coordenada revisada de cada apartamento (10 oct 2026)
-- Tres fuentes: enlace de mapa → TomTom → GPS de los escaneos. Solo Operación confirma.
-- Solo las coordenadas CONFIRMADAS se usan para el GPS de la limpieza.
-- Ejecutar DESPUES de 023. Se puede ejecutar varias veces. Todo UPDATE/DELETE lleva WHERE.

-- 1. Datos nuevos -----------------------------------------------------------------
alter table public.propiedades add column if not exists coord_estado text not null default 'sin';
alter table public.propiedades add column if not exists coord_fuente text;         -- enlace / tomtom / gps / manual
alter table public.propiedades add column if not exists coord_motivo text;         -- por qué está dudosa (una frase)
alter table public.propiedades add column if not exists coord_info jsonb;          -- resumen de TomTom, punto anterior…
alter table public.propiedades add column if not exists coord_confirmada_por uuid;
alter table public.propiedades add column if not exists coord_confirmada_en timestamptz;
alter table public.propiedades add column if not exists pueblo_tomtom text;        -- el pueblo como lo escribe TomTom
alter table public.eventos     add column if not exists propiedad_id uuid references public.propiedades(id) on delete cascade;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'propiedades_coord_estado_check') then
    alter table public.propiedades add constraint propiedades_coord_estado_check
      check (coord_estado in ('sin', 'propuesta', 'dudosa', 'confirmada'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'propiedades_coord_fuente_check') then
    alter table public.propiedades add constraint propiedades_coord_fuente_check
      check (coord_fuente is null or coord_fuente in ('enlace', 'tomtom', 'gps', 'manual'));
  end if;
end $$;
-- Las coordenadas que ya estaban escritas a mano quedan como "propuestas": Operación las confirma
update public.propiedades set coord_estado = 'propuesta', coord_fuente = 'manual'
where lat is not null and coord_estado = 'sin';

-- Los líderes y Operación pueden ver el estado; el código QR sigue oculto
grant select (id, codigo, nombre, zona, pueblo, direccion, mapa_url, camas_dobles, camas_indiv, sofas_cama, banos,
              notas, activa, es_prueba, creado_en, lat, lng, coord_estado, coord_fuente, coord_motivo, coord_info,
              coord_confirmada_en, pueblo_tomtom) on public.propiedades to authenticated;

-- 2. Ayudantes ---------------------------------------------------------------------
create or replace function public._en_malta(p_lat double precision, p_lng double precision)
returns boolean language sql immutable set search_path = ''
as $$ select p_lat between 35.78 and 36.10 and p_lng between 14.15 and 14.60 $$;
revoke execute on function public._en_malta(double precision, double precision) from public, anon, authenticated;

-- Escribir la coordenada desde las funciones de este archivo (el disparador de abajo las deja pasar)
create or replace function public._fijar_coord(p_prop uuid, p_lat double precision, p_lng double precision, p_estado text,
  p_fuente text, p_motivo text, p_info jsonb, p_pueblo text, p_que text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform set_config('opsflow.coord', '1', true);
  update public.propiedades set lat = p_lat, lng = p_lng, coord_estado = p_estado, coord_fuente = p_fuente,
    coord_motivo = p_motivo, coord_info = p_info, pueblo_tomtom = coalesce(p_pueblo, pueblo_tomtom),
    coord_confirmada_por = case when p_estado = 'confirmada' then (select auth.uid()) end,
    coord_confirmada_en  = case when p_estado = 'confirmada' then now() end
  where id = p_prop;
  perform set_config('opsflow.coord', '', true);
  insert into public.eventos (quien, que, propiedad_id) values ((select auth.uid()), p_que, p_prop);
end $$;
revoke execute on function public._fijar_coord(uuid, double precision, double precision, text, text, text, jsonb, text, text) from public, anon, authenticated;

-- 3. Cambios hechos a mano desde la ficha ----------------------------------------------
--   · El estado, la fuente y la confirmación no se pueden escribir directamente.
--   · Punto nuevo escrito a mano → "propuesta" (o "dudosa" si cae fuera de Malta).
--   · Cambia la dirección, el pueblo o el enlace → la coordenada vuelve a "propuesta".
create or replace function public._coord_cambios()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(current_setting('opsflow.coord', true), '') = '1' then return new; end if;
  if tg_op = 'INSERT' then
    new.coord_fuente := null; new.coord_motivo := null; new.coord_info := null; new.pueblo_tomtom := null;
    new.coord_confirmada_por := null; new.coord_confirmada_en := null; new.coord_estado := 'sin';
    if new.lat is not null then new.coord_estado := 'propuesta'; new.coord_fuente := 'manual'; end if;
  else
    new.coord_estado := old.coord_estado; new.coord_fuente := old.coord_fuente; new.coord_motivo := old.coord_motivo;
    new.coord_info := old.coord_info; new.pueblo_tomtom := old.pueblo_tomtom;
    new.coord_confirmada_por := old.coord_confirmada_por; new.coord_confirmada_en := old.coord_confirmada_en;
    if (new.lat, new.lng) is distinct from (old.lat, old.lng) then
      new.coord_confirmada_por := null; new.coord_confirmada_en := null; new.coord_info := null; new.coord_motivo := null;
      if new.lat is null then new.coord_estado := 'sin'; new.coord_fuente := null;
      else new.coord_estado := 'propuesta'; new.coord_fuente := 'manual';
      end if;
    elsif (new.direccion, new.pueblo, new.mapa_url) is distinct from (old.direccion, old.pueblo, old.mapa_url)
          and old.coord_estado <> 'sin' then
      new.coord_estado := 'propuesta'; new.coord_confirmada_por := null; new.coord_confirmada_en := null;
      new.coord_motivo := 'La dirección cambió: revisa el punto';
    end if;
  end if;
  if new.lat is not null and not public._en_malta(new.lat, new.lng) then
    new.coord_estado := 'dudosa'; new.coord_motivo := 'Fuera de Malta y Gozo';
  end if;
  return new;
end $$;
revoke execute on function public._coord_cambios() from public, anon, authenticated;
drop trigger if exists propiedades_coord on public.propiedades;
create trigger propiedades_coord before insert or update on public.propiedades
for each row execute function public._coord_cambios();

-- 4. Confirmar (solo Operación, después de mirar el punto en el mapa) -------------------
create or replace function public.ubicacion_confirmar(p_prop uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare p public.propiedades;
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación confirma ubicaciones.'; end if;
  select * into p from public.propiedades where id = p_prop;
  if not found then raise exception 'Esa propiedad no existe.'; end if;
  if p.lat is null then raise exception 'No hay ningún punto que confirmar.'; end if;
  if not public._en_malta(p.lat, p.lng) then raise exception 'El punto está fuera de Malta y Gozo: corrígelo antes.'; end if;
  perform public._fijar_coord(p_prop, p.lat, p.lng, 'confirmada', p.coord_fuente, null, p.coord_info, null, 'ubicación confirmada');
end $$;
revoke execute on function public.ubicacion_confirmar(uuid) from public, anon;
grant  execute on function public.ubicacion_confirmar(uuid) to authenticated;

-- 5. Lo que usa la función "geocodificar" (solo el servidor) ------------------------------
-- Qué buscar: las marcadas (si no están confirmadas) o, si no se marca ninguna, las activas sin coordenada. Máx. 50.
create or replace function public.ubicaciones_para_buscar(p_ids uuid[] default null)
returns table (id uuid, codigo text, direccion text, pueblo text, mapa_url text, lat double precision, lng double precision, coord_estado text)
language sql stable security definer set search_path = ''
as $$
  select p.id, p.codigo, p.direccion, p.pueblo, p.mapa_url, p.lat, p.lng, p.coord_estado
  from public.propiedades p
  where p.coord_estado <> 'confirmada'
    and (case when p_ids is null or cardinality(p_ids) = 0 then p.activa and p.coord_estado = 'sin' else p.id = any(p_ids) end)
  order by p.codigo limit 50
$$;
revoke execute on function public.ubicaciones_para_buscar(uuid[]) from public, anon, authenticated;
grant  execute on function public.ubicaciones_para_buscar(uuid[]) to service_role;

-- Guardar lo encontrado. Nunca pisa una confirmada. Devuelve el estado final (o 'confirmada' si no tocó nada).
create or replace function public.ubicacion_guardar(p_prop uuid, p_lat double precision, p_lng double precision, p_fuente text,
  p_dudosa boolean, p_motivo text, p_info jsonb default null, p_pueblo text default null)
returns text language plpgsql security definer set search_path = ''
as $$
declare p public.propiedades; v_estado text; v_motivo text := nullif(btrim(coalesce(p_motivo, '')), ''); d int;
        v_info jsonb := coalesce(p_info, '{}'::jsonb);
begin
  if coalesce(p_fuente, '') not in ('enlace', 'tomtom') then raise exception 'Fuente no válida.'; end if;
  if p_lat is null or p_lng is null then raise exception 'Faltan las coordenadas.'; end if;
  select * into p from public.propiedades where id = p_prop for update;
  if not found then raise exception 'Esa propiedad no existe.'; end if;
  if p.coord_estado = 'confirmada' then return 'confirmada'; end if;
  v_estado := case when coalesce(p_dudosa, false) then 'dudosa' else 'propuesta' end;
  if not public._en_malta(p_lat, p_lng) then
    v_estado := 'dudosa'; v_motivo := 'Fuera de Malta y Gozo';
  elsif p.lat is not null then
    -- Había otro punto (escrito a mano o del GPS): si están a más de 150 m, algo no cuadra
    d := public._distancia_m(p.lat, p.lng, p_lat, p_lng);
    if d > 150 then
      v_estado := 'dudosa';
      v_motivo := concat_ws(' · ', v_motivo, format('El punto anterior (%s) y %s están a %s m', coalesce(p.coord_fuente, 'manual'),
                  case p_fuente when 'enlace' then 'el enlace' else 'TomTom' end, d));
      v_info := v_info || jsonb_build_object('anterior', jsonb_build_object('lat', p.lat, 'lng', p.lng, 'fuente', p.coord_fuente));
    end if;
  end if;
  if v_estado = 'propuesta' then v_motivo := null; end if;
  perform public._fijar_coord(p_prop, p_lat, p_lng, v_estado, p_fuente, left(v_motivo, 200), v_info, p_pueblo,
    format('ubicación %s (%s)', v_estado, p_fuente));
  return v_estado;
end $$;
revoke execute on function public.ubicacion_guardar(uuid, double precision, double precision, text, boolean, text, jsonb, text) from public, anon, authenticated;
grant  execute on function public.ubicacion_guardar(uuid, double precision, double precision, text, boolean, text, jsonb, text) to service_role;

-- 6. GPS de los escaneos ------------------------------------------------------------------
-- La distancia solo se calcula contra una coordenada CONFIRMADA. Con buena precisión (≤ 30 m)
-- se guarda también el punto del teléfono, para proponer o vigilar la coordenada del apartamento.
create or replace function public._gps(p_prop uuid, p_lat double precision, p_lng double precision, p_prec double precision)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_lat double precision; v_lng double precision; v_est text; r jsonb;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return jsonb_build_object('sin_gps', true);
  end if;
  select lat, lng, coord_estado into v_lat, v_lng, v_est from public.propiedades where id = p_prop;
  r := jsonb_build_object('sin_gps', false,
    'dist', case when v_est = 'confirmada' and v_lat is not null then public._distancia_m(v_lat, v_lng, p_lat, p_lng) end,
    'prec', case when p_prec is null or p_prec < 0 then null else least(round(p_prec), 100000)::int end);
  if p_prec is not null and p_prec between 0 and 30 then
    r := r || jsonb_build_object('lat', round(p_lat::numeric, 6), 'lng', round(p_lng::numeric, 6), 'en', now());
  end if;
  return r;
end $$;
revoke execute on function public._gps(uuid, double precision, double precision, double precision) from public, anon, authenticated;

-- Escaneos buenos (≤ 30 m) de una propiedad, opcionalmente desde una fecha
create or replace function public._escaneos(p_prop uuid, p_desde timestamptz default null)
returns table (lat double precision, lng double precision, en timestamptz, prec int)
language sql stable security definer set search_path = ''
as $$
  select (g.value->>'lat')::double precision, (g.value->>'lng')::double precision, (g.value->>'en')::timestamptz, (g.value->>'prec')::int
  from public.limpiezas l, jsonb_each(coalesce(l.gps, '{}'::jsonb)) g
  where l.propiedad_id = p_prop and jsonb_typeof(g.value) = 'object' and g.value ? 'lat'
    and (g.value->>'prec')::int <= 30
    and (p_desde is null or (g.value->>'en')::timestamptz >= p_desde)
$$;
revoke execute on function public._escaneos(uuid, timestamptz) from public, anon, authenticated;

-- Tras cada escaneo:
--   · sin coordenada → se propone la del teléfono
--   · propuesta (de otra fuente) y el teléfono cae a más de 150 m → dudosa
--   · confirmada y 3+ escaneos desde la confirmación caen de media a más de 100 m → dudosa
create or replace function public._revisar_ubicacion(p_prop uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare p public.propiedades; e record; n int; m int;
begin
  select * into p from public.propiedades where id = p_prop;
  if not found then return; end if;
  if p.coord_estado = 'sin' then
    select * into e from public._escaneos(p_prop) order by prec, en desc limit 1;
    if found then
      perform public._fijar_coord(p_prop, e.lat, e.lng, case when public._en_malta(e.lat, e.lng) then 'propuesta' else 'dudosa' end,
        'gps', case when public._en_malta(e.lat, e.lng) then null else 'Fuera de Malta y Gozo' end,
        jsonb_build_object('prec', e.prec), null, 'ubicación propuesta (gps)');
    end if;
  elsif p.coord_estado = 'propuesta' and p.coord_fuente <> 'gps' then
    select * into e from public._escaneos(p_prop) order by en desc limit 1;
    if found then
      m := public._distancia_m(p.lat, p.lng, e.lat, e.lng);
      if m > 150 then
        perform public._fijar_coord(p_prop, p.lat, p.lng, 'dudosa', p.coord_fuente,
          format('El GPS de un escaneo cae a %s m del punto propuesto', m),
          coalesce(p.coord_info, '{}'::jsonb) || jsonb_build_object('gps', jsonb_build_object('lat', e.lat, 'lng', e.lng)), null,
          'ubicación dudosa (gps)');
      end if;
    end if;
  elsif p.coord_estado = 'confirmada' then
    select count(*), round(avg(public._distancia_m(p.lat, p.lng, s.lat, s.lng))) into n, m
    from public._escaneos(p_prop, p.coord_confirmada_en) s;
    if n >= 3 and m > 100 then
      perform public._fijar_coord(p_prop, p.lat, p.lng, 'dudosa', p.coord_fuente,
        format('El GPS de %s escaneos cae a %s m de media', n, m), p.coord_info, null, 'ubicación dudosa (gps)');
    end if;
  end if;
end $$;
revoke execute on function public._revisar_ubicacion(uuid) from public, anon, authenticated;

create or replace function public._limpieza_gps()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.gps is distinct from old.gps and new.gps is not null then perform public._revisar_ubicacion(new.propiedad_id); end if;
  return new;
end $$;
revoke execute on function public._limpieza_gps() from public, anon, authenticated;
drop trigger if exists limpiezas_gps on public.limpiezas;
create trigger limpiezas_gps after update of gps on public.limpiezas
for each row execute function public._limpieza_gps();

-- Resumen para la ficha (solo Operación): escaneos buenos y distancia media al punto actual
create or replace function public.ubicacion_escaneos(p_prop uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare p public.propiedades; n int; m int;
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  select * into p from public.propiedades where id = p_prop;
  select count(*), case when p.lat is null then null else round(avg(public._distancia_m(p.lat, p.lng, s.lat, s.lng))) end
    into n, m from public._escaneos(p_prop) s;
  return jsonb_build_object('n', n, 'media_m', m);
end $$;
revoke execute on function public.ubicacion_escaneos(uuid) from public, anon;
grant  execute on function public.ubicacion_escaneos(uuid) to authenticated;

-- 7. Tráfico: un pueblo también se reconoce por cómo lo escribe TomTom (solo coordenadas confirmadas) ----
create or replace function public._zona_de_pueblo(p_pueblo text)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select p.zona::text from public.propiedades p
    where p.activa and coalesce(p_pueblo, '') <> ''
      and (lower(regexp_replace(p.pueblo, '[^[:alpha:]]', '', 'g')) = lower(regexp_replace(p_pueblo, '[^[:alpha:]]', '', 'g'))
           or (p.coord_estado = 'confirmada' and p.pueblo_tomtom is not null
               and lower(regexp_replace(p.pueblo_tomtom, '[^[:alpha:]]', '', 'g')) = lower(regexp_replace(p_pueblo, '[^[:alpha:]]', '', 'g'))))
    group by p.zona order by count(*) desc limit 1), 'General')
$$;
revoke execute on function public._zona_de_pueblo(text) from public, anon, authenticated;

-- Comprobación: debe salir una fila con el número de propiedades por estado
select coord_estado, count(*) from public.propiedades group by 1 order by 1;


-- ═══════════════ 27-PEGAR-rutas.sql ═══════════════
-- OpsFlow · rutas con TomTom, hora de entrada de los equipos y aviso "listo en 30 min" (12 oct 2026)
-- SPEC-rutas-driver.md (aprobado). Ejecutar DESPUES de 025. Se puede ejecutar varias veces. Todo UPDATE/DELETE lleva WHERE.
--   1. Hora de entrada de cada equipo (la fija la líder de limpieza; por defecto 11:00) = hora límite de sus bolsas.
--   2. "Ready for pickup in 30 min": el cleaner avisa y los drivers de la zona lo ven y lo cogen.
--   3. Punto de salida (linens / bodega) y la última ruta calculada de cada driver (la escribe la función "ruta").

-- 1. Hora de entrada por equipo y día ---------------------------------------------------
create table if not exists public.entradas_equipo (
  fecha        date not null,
  cleaner      uuid not null references public.perfiles(id),
  hora         time not null check (hora between '05:00' and '20:00'),
  fijada_por   uuid, fijada_en timestamptz not null default now(),
  primary key (fecha, cleaner)
);
alter table public.entradas_equipo enable row level security;
revoke all on public.entradas_equipo from anon;
revoke insert, update, delete, truncate on public.entradas_equipo from authenticated;
drop policy if exists "entradas: lectura" on public.entradas_equipo;
create policy "entradas: lectura" on public.entradas_equipo for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or (select public.mi_departamento()) in ('Limpieza', 'Drivers') and (select public.mi_nivel()) = 'lider'
  or (select public.mi_departamento()) = 'Drivers'
  or cleaner = (select auth.uid())
);

-- Hora de entrada de un equipo (11:00 si nadie la cambió) y hora límite de la bolsa de una limpieza
create or replace function public._hora_entrada(p_fecha date, p_cleaner uuid)
returns time language sql stable security definer set search_path = ''
as $$ select coalesce((select hora from public.entradas_equipo where fecha = p_fecha and cleaner = p_cleaner), time '11:00') $$;
create or replace function public._limite_bolsa(p_limpieza uuid)
returns timestamptz language sql stable security definer set search_path = ''
as $$ select (l.fecha + public._hora_entrada(l.fecha, l.asignada_a)) at time zone 'Europe/Malta' from public.limpiezas l where l.id = p_limpieza $$;
revoke execute on function public._hora_entrada(date, uuid), public._limite_bolsa(uuid) from public, anon, authenticated;

-- Líder de limpieza u Operación: fijar la hora de entrada de un equipo
create or replace function public.fijar_entrada(p_fecha date, p_cleaner uuid, p_hora time)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo la líder de limpieza u Operación fijan la hora de entrada.'; end if;
  if p_hora is null or p_hora < time '05:00' or p_hora > time '20:00' then raise exception 'La hora tiene que estar entre las 05:00 y las 20:00.'; end if;
  if p_fecha < (now() at time zone 'Europe/Malta')::date then raise exception 'No se cambia la hora de un día que ya pasó.'; end if;
  if not exists (select 1 from public.perfiles where id = p_cleaner and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception 'Ese equipo no existe.';
  end if;
  insert into public.entradas_equipo (fecha, cleaner, hora, fijada_por) values (p_fecha, p_cleaner, p_hora, (select auth.uid()))
  on conflict (fecha, cleaner) do update set hora = excluded.hora, fijada_por = excluded.fijada_por, fijada_en = now();
  insert into public.eventos (quien, que) values ((select auth.uid()),
    'hora de entrada ' || to_char(p_hora, 'HH24:MI') || ' · ' || (select nombre from public.perfiles where id = p_cleaner) || ' · ' || to_char(p_fecha, 'DD/MM'));
end $$;

-- Equipos con limpiezas ese día y su hora de entrada (pantalla de reparto)
create or replace function public.entradas_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public._lider_limpieza() or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo los líderes u Operación.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('cleaner', p.id, 'nombre', p.nombre, 'zona', p.zona,
      'hora', to_char(public._hora_entrada(p_fecha, p.id), 'HH24:MI'),
      'fijada', exists (select 1 from public.entradas_equipo e where e.fecha = p_fecha and e.cleaner = p.id),
      'limpiezas', (select count(*) from public.limpiezas l where l.fecha = p_fecha and l.asignada_a = p.id and l.estado::text <> 'cancelada'))
      order by p.nombre)
    from public.perfiles p
    where exists (select 1 from public.limpiezas l where l.fecha = p_fecha and l.asignada_a = p.id and l.estado::text <> 'cancelada')), '[]'::jsonb);
end $$;

-- 2. Aviso "listo para recoger en 30 min" -------------------------------------------------
alter table public.pendientes add column if not exists listo_a timestamptz;   -- solo en la recogida que nace del aviso

create or replace function public.avisar_listo(p_limpieza uuid)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_id uuid; v_prio boolean;
begin
  v := public._mi_limpieza(p_limpieza);
  if v.estado <> 'en_curso' then raise exception 'Start the cleaning first.'; end if;
  if exists (select 1 from public.pendientes where limpieza_id = v.id and tipo = 'recogida' and listo_a is not null) then
    raise exception 'You already told the drivers.';
  end if;
  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, listo_a)
  values (v.id, v.propiedad_id, v.zona, v.fecha, 'recogida', 'Listo para recoger', 1, coalesce(v_prio, false),
          (select auth.uid()), v.es_prueba, now() + interval '30 minutes')
  returning id into v_id;
  perform public._evento('aviso: listo para recoger en 30 min', v.id, v_id);
  return v_id;
end $$;

-- Deshacer el aviso (solo en los 5 minutos siguientes y si nadie lo ha recogido)
create or replace function public.deshacer_listo(p_limpieza uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; pe public.pendientes;
begin
  v := public._mi_limpieza(p_limpieza);
  select * into pe from public.pendientes where limpieza_id = v.id and tipo = 'recogida' and listo_a is not null for update;
  if not found then raise exception 'There is nothing to undo.'; end if;
  if pe.estado <> 'abierto' then raise exception 'A driver already picked it up.'; end if;
  if pe.creado_en < now() - interval '5 minutes' then raise exception 'Too late to undo (5 minutes). Call your leader.'; end if;
  delete from public.pendientes where id = pe.id;
  perform public._evento('aviso de recogida deshecho por el cleaner', v.id, null);
end $$;

-- 3. Punto de salida (linens / bodega) y rutas calculadas --------------------------------
create table if not exists public.puntos_base (
  clave       text primary key,
  nombre      text not null,
  enlace      text,
  lat         double precision, lng double precision,
  cambiado_por uuid, cambiado_en timestamptz not null default now()
);
alter table public.puntos_base enable row level security;
revoke all on public.puntos_base from anon;
revoke insert, update, delete, truncate on public.puntos_base from authenticated;
drop policy if exists "puntos: lectura" on public.puntos_base;
create policy "puntos: lectura" on public.puntos_base for select to authenticated using (
  (select public.mi_nivel()) = 'operacion' or (select public.mi_departamento()) = 'Drivers');
-- El enlace que dio Ivan; la función "ruta" saca la coordenada la primera vez que hace falta
insert into public.puntos_base (clave, nombre, enlace) values ('bodega', 'Linens / bodega', 'https://maps.app.goo.gl/eDVmMA2AUQfzM4My5')
on conflict (clave) do nothing;

-- Operación: cambiar el punto (coordenadas, o un enlace nuevo para que la función lo resuelva)
create or replace function public.fijar_bodega(p_lat double precision, p_lng double precision, p_enlace text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación cambia el punto de bodega.'; end if;
  if p_lat is null and nullif(btrim(coalesce(p_enlace, '')), '') is null then raise exception 'Da las coordenadas o un enlace de mapa.'; end if;
  if p_lat is not null and not public._en_malta(p_lat, p_lng) then raise exception 'Ese punto está fuera de Malta y Gozo.'; end if;
  update public.puntos_base set lat = p_lat, lng = case when p_lat is null then null else p_lng end,
         enlace = coalesce(nullif(btrim(coalesce(p_enlace, '')), ''), enlace), cambiado_por = (select auth.uid()), cambiado_en = now()
   where clave = 'bodega';
  insert into public.eventos (quien, que) values ((select auth.uid()), 'punto de bodega cambiado');
end $$;

-- Servidor (función "ruta"): guardar la coordenada resuelta del enlace, solo si aún no hay
create or replace function public.guardar_bodega_resuelta(p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public._en_malta(p_lat, p_lng) then raise exception 'Fuera de Malta.'; end if;
  update public.puntos_base set lat = p_lat, lng = p_lng, cambiado_en = now() where clave = 'bodega' and lat is null;
end $$;

create table if not exists public.rutas_driver (
  driver       uuid primary key references public.perfiles(id),
  fecha        date not null,
  calculada_en timestamptz not null default now(),
  firma        text not null,
  datos        jsonb not null
);
alter table public.rutas_driver enable row level security;
revoke all on public.rutas_driver from anon;
revoke insert, update, delete, truncate on public.rutas_driver from authenticated;
drop policy if exists "rutas: lectura" on public.rutas_driver;
create policy "rutas: lectura" on public.rutas_driver for select to authenticated using (
  driver = (select auth.uid())
  or (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Drivers'));

create or replace function public.guardar_ruta(p_driver uuid, p_firma text, p_datos jsonb)
returns void language sql security definer set search_path = ''
as $$
  insert into public.rutas_driver (driver, fecha, calculada_en, firma, datos)
  values (p_driver, (now() at time zone 'Europe/Malta')::date, now(), p_firma, p_datos)
  on conflict (driver) do update set fecha = excluded.fecha, calculada_en = now(), firma = excluded.firma, datos = excluded.datos
$$;

-- Servidor: las paradas de un driver (sus bolsas en el camión y las tareas que ha cogido) con punto y horas
create or replace function public.paradas_driver(p_driver uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not exists (select 1 from public.perfiles where id = p_driver and activo and departamento = 'Drivers' and nivel = 'operador') then
    raise exception 'Solo para drivers activos.';
  end if;
  return jsonb_build_object(
    'bodega', (select jsonb_build_object('lat', lat, 'lng', lng, 'enlace', enlace) from public.puntos_base where clave = 'bodega'),
    'paradas', coalesce((select jsonb_agg(x) from (
      select jsonb_build_object('id', b.id, 'clase', 'bolsa', 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end,
        'coord', p.coord_estado, 'limite', public._limite_bolsa(l.id), 'no_antes', null,
        'equipo', to_char(public._hora_entrada(l.fecha, l.asignada_a), 'HH24:MI'),
        'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end) as x
      from public.bolsas b join public.limpiezas l on l.id = b.limpieza_id join public.propiedades p on p.id = b.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where b.driver = p_driver and b.estado = 'en_camion'
      union all
      select jsonb_build_object('id', pe.id, 'clase', pe.tipo::text, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end,
        'coord', p.coord_estado,
        -- faltantes de linens: antes del check-in de hoy; basura y útiles no tienen hora límite
        'limite', case when pe.tipo = 'linens' and c.fecha = v_hoy and c.hora_entrada is not null
                       then (c.fecha + c.hora_entrada) at time zone 'Europe/Malta' end,
        'no_antes', case when pe.tipo = 'recogida' and l.estado <> 'terminada' then pe.listo_a end,
        'listo', pe.listo_a is not null, 'equipo', null,
        'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end)
      from public.pendientes pe join public.limpiezas l on l.id = pe.limpieza_id join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.tomado_por = p_driver and public._en_driver(pe) and pe.fecha >= v_hoy - 7) s), '[]'::jsonb));
end $$;

-- Líder de drivers u Operación: la última ruta de hoy de cada driver
create or replace function public.rutas_hoy()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo el líder de drivers u Operación.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('driver', p.nombre, 'zona', p.zona, 'calculada_en', r.calculada_en, 'datos', r.datos) order by p.nombre)
    from public.rutas_driver r join public.perfiles p on p.id = r.driver
    where r.fecha = (now() at time zone 'Europe/Malta')::date and p.activo), '[]'::jsonb);
end $$;

-- 4. Pantallas que cambian ---------------------------------------------------------------
-- Tablero de zonas: + hora de "listo", si la limpieza ya terminó y el punto confirmado del apto
create or replace function public.tablero_zonas()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'zona', (x->>'prioridad')::int desc, x->>'entrada' nulls last, x->>'desde') from (
    select jsonb_build_object(
      'id', pe.id, 'zona', pe.zona, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'items', pe.items,
      'foto', pe.foto, 'incidencia', pe.incidencia, 'fecha', pe.fecha,
      'desde', coalesce(pe.preparado_en, pe.creado_en),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end,
      'prioridad', case when c.fecha = v_hoy and c.hora_entrada is not null then 1 else 0 end,
      'tomado_por', t.nombre,
      'listo_a', to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI'), 'terminada', l.estado = 'terminada',
      'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end, 'coord', p.coord_estado, 'mio', pe.tomado_por = (select auth.uid()), 'asignado', pe.asignado_por is not null) as x
    from public.pendientes pe
    join public.propiedades p on p.id = pe.propiedad_id
    join public.limpiezas l on l.id = pe.limpieza_id
    join public.checkouts c on c.id = l.checkout_id
    left join public.perfiles t on t.id = pe.tomado_por
    where public._en_driver(pe) and pe.fecha >= v_hoy - 7) s), '[]'::jsonb);
end $$;

-- Lista del driver: sus bolsas (con la hora límite = entrada del equipo y el punto) y las bolsas listas en linens hoy
create or replace function public.mis_trabajos()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return jsonb_build_object(
    'bolsas', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'limpieza_id', b.limpieza_id, 'zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'incidencia', b.incidencia,
        'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end,
        'limite', to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI'),
        'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end, 'coord', p.coord_estado)
        order by public._limite_bolsa(l.id), (c.fecha = v_hoy and c.hora_entrada is not null) desc, c.hora_entrada, p.codigo)
      from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
      join public.checkouts c on c.id = l.checkout_id
      where b.driver = (select auth.uid()) and b.estado = 'en_camion'), '[]'::jsonb),
    'listas', coalesce((select jsonb_agg(jsonb_build_object('zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'limite', to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI'))
        order by public._limite_bolsa(l.id), c.hora_entrada nulls last, p.codigo)
      from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
      join public.checkouts c on c.id = l.checkout_id
      where b.fecha = v_hoy and b.estado = 'preparada' and l.estado::text <> 'cancelada'), '[]'::jsonb));
end $$;

-- Día del cleaner: + la hora de "listo" del aviso de recogida (y cuándo lo mandó, para poder deshacer 5 min)
create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden, 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar, 'linens_revisado', l.linens_revisado,
      'bolsa', (select jsonb_build_object('estado', b.estado, 'entregada_en', to_char(b.entregada_en at time zone 'Europe/Malta', 'HH24:MI'), 'comentario', b.comentario) from public.bolsas b where b.limpieza_id = l.id),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado, 'items', pe.items,
                     'listo_a', to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI'), 'listo_creado', case when pe.listo_a is not null then pe.creado_en end) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and l.asignada_a = (select auth.uid()) and l.estado::text <> 'cancelada'
      and public.mi_nivel() is not null
  ) t
$$;

-- Cierre: igual que en 017, pero la basura se une al aviso "listo en 30 min" si lo hubo
create or replace function public.cerrar_limpieza(
  p_id uuid, p_qr text, p_escoba boolean, p_squeegee boolean, p_recogedor boolean,
  p_basura boolean, p_llaves boolean, p_motivo_llaves text default null, p_lat double precision default null, p_lng double precision default null, p_prec double precision default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v public.limpiezas; v_faltan int; v_fotos int; v_prop public.propiedades; v_prio boolean;
  v_utiles text[] := '{}'; v_ids uuid[] := '{}'; v_id uuid; v_foto text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  select count(*) into v_faltan from public.checklist_pasos p
   where p.tipo = v.tipo and p.activo and p.obligatorio and not (v.checklist ? p.id::text);
  if v_faltan > 0 then raise exception 'Checklist not finished: % step(s) left.', v_faltan; end if;
  select count(distinct sala) into v_fotos from public.fotos_cierre
   where limpieza_id = p_id and sala in ('bedroom', 'bathroom', 'kitchen', 'living');
  if v_fotos < 4 then raise exception 'Take the 4 photos first (% of 4).', v_fotos; end if;
  if p_escoba is null or p_squeegee is null or p_recogedor is null or p_basura is null or p_llaves is null then
    raise exception 'Answer the 3 closing questions first.';
  end if;
  if p_basura then
    select ruta into v_foto from public.fotos_cierre where limpieza_id = p_id and sala = 'basura';
    if v_foto is null then raise exception 'Take a photo of the trash first.'; end if;
  end if;
  if not p_llaves and length(btrim(coalesce(p_motivo_llaves, ''))) < 3 then
    raise exception 'Write why the keys are not in the key box.';
  end if;
  select * into v_prop from public.propiedades where id = v.propiedad_id;
  if p_qr is not null and btrim(p_qr) <> 'OPSFLOW:' || v_prop.qr_token then
    raise exception 'This QR is not for %. Scan the sticker inside this apartment.', v_prop.codigo;
  end if;

  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  if not p_escoba    then v_utiles := v_utiles || 'escoba'::text; end if;
  if not p_squeegee  then v_utiles := v_utiles || 'squeegee'::text; end if;
  if not p_recogedor then v_utiles := v_utiles || 'recogedor'::text; end if;
  if cardinality(v_utiles) > 0 then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'utiles'::text::public.tipo_pendiente,
            'Falta: ' || array_to_string(v_utiles, ', '), cardinality(v_utiles), coalesce(v_prio, false), (select auth.uid()), v.es_prueba)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: faltan útiles', v.id, v_id);
  end if;
  if p_basura then
    -- Si ya avisó "listo en 30 min", la basura va en esa misma recogida (no se crea otra)
    v_id := null;
    select id into v_id from public.pendientes
     where limpieza_id = v.id and tipo = 'recogida' and listo_a is not null and estado = 'abierto';
    if v_id is not null then
      update public.pendientes set detalle = 'Basura dejada en el apto', foto = v_foto where id = v_id;
      perform public._evento('cierre: basura en el apto (va en el aviso de recogida)', v.id, v_id);
    else
      insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, foto)
      values (v.id, v.propiedad_id, v.zona, v.fecha, 'recogida', 'Basura dejada en el apto', 1, coalesce(v_prio, false),
              (select auth.uid()), v.es_prueba, v_foto)
      returning id into v_id;
      perform public._evento('cierre: basura en el apto', v.id, v_id);
    end if;
    v_ids := v_ids || v_id;
  end if;

  update public.limpiezas set estado = 'terminada', fin = now(), fin_qr = (p_qr is not null),
    gps = coalesce(gps, '{}'::jsonb) || jsonb_build_object('fin', public._gps(v.propiedad_id, p_lat, p_lng, p_prec)),
    cierre = jsonb_build_object('escoba', p_escoba, 'squeegee', p_squeegee, 'recogedor', p_recogedor,
                                'basura', p_basura, 'llaves', p_llaves,
                                'motivo_llaves', case when p_llaves then null else left(btrim(p_motivo_llaves), 200) end)
  where id = p_id;
  perform public._evento('limpieza terminada' || case when p_qr is null then ' (salida sin QR)' else '' end
                         || case when p_llaves then '' else ' · llaves NO en key box' end, p_id, null);
  return jsonb_build_object('pendientes', to_jsonb(v_ids), 'llaves', p_llaves);
end $$;

-- Avisos: + "listo para recoger a las HH:MM" a los drivers de la zona
create or replace function public.avisos_para(p_tipo text, p_id uuid default null, p_fecha date default null)
returns table (perfil_id uuid, titulo text, cuerpo text, url text, clave text, telefonos jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  pe public.pendientes; li public.limpiezas; pr public.propiedades; ck public.checkouts;
  v_aviso text; v_ok boolean := true;
begin
  create temp table if not exists _dest (perfil_id uuid, idioma text, t_es text, t_en text, c_es text, c_en text, url text, clave text) on commit drop;
  truncate _dest;

  if p_tipo = 'pendiente' then
    select * into pe from public.pendientes where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = pe.propiedad_id;
    select c.* into ck from public.checkouts c join public.limpiezas l on l.checkout_id = c.id where l.id = pe.limpieza_id;
    v_aviso := 'pendiente:' || pe.id || ':' || pe.estado;

    if pe.asignado_por is not null and pe.tomado_por is not null and pe.tomado_en > now() - interval '2 minutes' then
      -- 14. El líder asigna una tarea a un driver concreto → ese driver
      insert into _dest select p.id, p.idioma,
        'Asignado a ti: ' || pr.codigo, 'Assigned to you: ' || pr.codigo,
        pr.pueblo || ' · ' || case when pe.tipo = 'recogida' then 'recoger' else 'entregar' end,
        pr.pueblo || ' · ' || case when pe.tipo = 'recogida' then 'pick up' else 'deliver' end,
        './', 'pendiente:' || pe.id || ':asignado:' || extract(epoch from pe.tomado_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = pe.tomado_por;

    elsif pe.incidencia is not null and pe.incidencia_en > now() - interval '2 minutes'
       and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto')) then
      -- 11. El driver no pudo entregar/recoger → lider de drivers
      insert into _dest select p.id, p.idioma,
        'No se pudo entregar: ' || pr.codigo, 'Couldn''t deliver: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.incidencia, pr.pueblo || ' · ' || pe.incidencia,
        './?v=drivers', 'pendiente:' || pe.id || ':incidencia:' || extract(epoch from pe.incidencia_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Drivers'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Deliver: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.listo_a is not null then
      -- 15. El cleaner avisa "listo en 30 min" → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Listo a las ' || to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI') || ': ' || pr.codigo,
        'Ready at ' || to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI') || ': ' || pr.codigo,
        pr.pueblo || ' · recoger basura y linens sucios', pr.pueblo || ' · pick up trash & dirty linens',
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.foto is not null then
      -- 4b. Basura dejada en el apto (con foto) → drivers de la zona y lider de drivers
      insert into _dest select p.id, p.idioma,
        'Basura en el apto: ' || pr.codigo, 'Trash left: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.detalle, pr.pueblo || ' · pick it up (photo in the app)',
        './', null
      from public.perfiles p where p.activo and p.departamento = 'Drivers'
        and ((p.nivel = 'operador' and p.zona = pe.zona) or (p.nivel = 'lider' and (p.zona is null or p.zona = pe.zona)));

    elsif pe.tipo::text = 'utiles' and pe.estado = 'abierto' then
      -- 8. Faltan utiles → lider de bodega
      insert into _dest select p.id, p.idioma,
        'Útiles: ' || pe.detalle, 'Tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=bodega', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Bodega'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo::text = 'utiles' and pe.estado = 'preparado' then
      -- 9. Utiles preparados → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar útiles: ' || pe.detalle, 'Deliver tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' then
      -- 4. Recogida → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Recoger: basura y linens sucios', 'Pick up: trash & dirty linens',
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'linens' and pe.estado = 'entregado' then
      -- 5. Entregado → el cleaner que lo pidio
      insert into _dest select p.id, p.idioma,
        'Entregado: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Delivered: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=seguimiento', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en where true;  -- Supabase exige WHERE en todo UPDATE
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    if li.estado = 'terminada' and li.cierre->>'llaves' = 'false' then
      -- 10. Llaves NO dejadas en el key box → lider de limpieza y lider de drivers (urgente)
      insert into _dest select p.id, p.idioma,
        '⚠ Llaves NO en el key box: ' || pr.codigo, '⚠ Keys NOT in the key box: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''), pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''),
        case when p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, 'limpieza:' || li.id || ':llaves:' || p.id
      from public.perfiles p
      where p.activo and p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona);
      v_aviso := 'limpieza:' || li.id || ':llaves';
    elsif li.estado::text = 'cancelada' and li.publicada then
      -- 12. Limpieza cancelada → su cleaner
      insert into _dest select p.id, p.idioma,
        'Cancelada: ' || pr.codigo, 'Cancelled: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''), pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''),
        './', 'limpieza:' || li.id || ':cancelada:' || p.id
      from public.perfiles p where p.activo and p.id = li.asignada_a;
      v_aviso := 'limpieza:' || li.id || ':cancelada';
    elsif li.estado = 'asignada' and li.publicada and li.reabierta_en > now() - interval '2 minutes' then
      -- 13. Limpieza reabierta (tras "no pude entrar") → su cleaner
      insert into _dest select p.id, p.idioma,
        'Reabierta: ' || pr.codigo, 'Reopened: ' || pr.codigo,
        pr.pueblo || ' · vuelve a tu lista', pr.pueblo || ' · back on your list',
        './', 'limpieza:' || li.id || ':reabierta:' || extract(epoch from li.reabierta_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = li.asignada_a;
      v_aviso := 'limpieza:' || li.id || ':reabierta';
    elsif li.estado <> 'no_pude_entrar' then
      return;
    else
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));
    end if;

  elsif p_tipo = 'orden' then
    if p_fecha is null then return; end if;
    -- 1. Orden publicado → cada cleaner con limpiezas publicadas ese dia
    --    (la clave lleva cuantas tiene: si el lider le anade otra y publica, le vuelve a sonar)
    insert into _dest select p.id, p.idioma,
      'Orden de limpieza listo', 'Your cleaning order is ready',
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartamento' || case when count(*) > 1 then 's' else '' end,
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartment' || case when count(*) > 1 then 's' else '' end,
      './', 'orden:' || p_fecha || ':' || p.id || ':' || count(*)
    from public.limpiezas l join public.perfiles p on p.id = l.asignada_a
    where l.fecha = p_fecha and l.publicada and p.activo
    group by p.id, p.idioma;

  else
    return;
  end if;

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id) where true;

  -- Apuntar los nuevos; los que ya estaban apuntados no salen otra vez
  return query
  with nuevos as (
    insert into public.avisos_enviados (clave, perfil_id, titulo)
    select d.clave, d.perfil_id, case when d.idioma = 'es' then d.t_es else d.t_en end from _dest d
    on conflict (clave) do nothing
    returning avisos_enviados.clave
  )
  select d.perfil_id,
         case when d.idioma = 'es' then d.t_es else d.t_en end,
         case when d.idioma = 'es' then d.c_es else d.c_en end,
         d.url, d.clave,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                   from public.suscripciones s where s.perfil_id = d.perfil_id), '[]'::jsonb)
  from _dest d join nuevos n on n.clave = d.clave;
end $$;

-- 5. Permisos ----------------------------------------------------------------------------
revoke execute on function public.fijar_entrada(date, uuid, time), public.entradas_dia(date), public.avisar_listo(uuid),
  public.deshacer_listo(uuid), public.fijar_bodega(double precision, double precision, text), public.rutas_hoy() from public, anon;
grant  execute on function public.fijar_entrada(date, uuid, time), public.entradas_dia(date), public.avisar_listo(uuid),
  public.deshacer_listo(uuid), public.fijar_bodega(double precision, double precision, text), public.rutas_hoy() to authenticated;
revoke execute on function public.guardar_bodega_resuelta(double precision, double precision), public.guardar_ruta(uuid, text, jsonb),
  public.paradas_driver(uuid) from public, anon, authenticated;
grant  execute on function public.guardar_bodega_resuelta(double precision, double precision), public.guardar_ruta(uuid, text, jsonb),
  public.paradas_driver(uuid) to service_role;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;


-- ═══════════════ 29-PEGAR-ubicaciones_prueba.sql ═══════════════
-- OpsFlow · puntos REALES de Malta para los 20 apartamentos de PRUEBA (TEST-N01 … TEST-N20), zona Norte
-- Para que TomTom pueda armar rutas de verdad en el piloto. Ejecutar DESPUÉS de 27. Se puede ejecutar varias veces.
-- · Son puntos en calles públicas de cada pueblo (sacados de TomTom), SIN número de portal: no son apartamentos de 360.
-- · Solo toca propiedades marcadas como prueba (es_prueba) cuyo código empieza por TEST-N. Quedan "confirmadas".
-- · Al final muestra las 20 filas: todas deben decir "confirmada".
do $$
declare r record; n int := 0;
begin
  perform set_config('opsflow.coord', '1', true);   -- el estado se escribe aquí a propósito (solo prueba)
  for r in select * from (values
    ('TEST-N01', 'Triq Sammy Bartolo (punto de prueba)',        'Mellieħa',       35.957523, 14.363112),
    ('TEST-N02', 'Triq il-Qigħan (punto de prueba)',             'Mellieħa',       35.955490, 14.359308),
    ('TEST-N03', 'Triq il-Mitħna l-Ġdida (punto de prueba)',     'Mellieħa',       35.958961, 14.360405),
    ('TEST-N04', 'Dawret San Pawl (punto de prueba)',            'St Paul''s Bay', 35.946827, 14.398963),
    ('TEST-N05', 'Triq San Ġorġ (punto de prueba)',              'St Paul''s Bay', 35.947868, 14.403480),
    ('TEST-N06', 'Dawret San Pawl, lado este (punto de prueba)', 'St Paul''s Bay', 35.946648, 14.401804),
    ('TEST-N07', 'Triq in-Nakkri (punto de prueba)',             'Qawra',          35.955120, 14.421247),
    ('TEST-N08', 'Triq il-Qawra (punto de prueba)',              'Qawra',          35.956032, 14.424153),
    ('TEST-N09', 'Triq il-Fliegu (punto de prueba)',             'Qawra',          35.952164, 14.419245),
    ('TEST-N10', 'Triq is-Sallur (punto de prueba)',             'Qawra',          35.957466, 14.423023),
    ('TEST-N11', 'Triq il-Gandoffli (punto de prueba)',          'Buġibba',        35.950974, 14.413501),
    ('TEST-N12', 'Triq it-Turisti (punto de prueba)',            'Buġibba',        35.949024, 14.416312),
    ('TEST-N13', 'Dawret il-Gżejjer (punto de prueba)',          'Buġibba',        35.952152, 14.410065),
    ('TEST-N14', 'Triq J. Quintinus (punto de prueba)',          'Buġibba',        35.950199, 14.417872),
    ('TEST-N15', 'Telgħet ix-Xemxija (punto de prueba)',         'Xemxija',        35.950420, 14.385786),
    ('TEST-N16', 'Triq Raddet ir-Roti (punto de prueba)',        'Xemxija',        35.950157, 14.384017),
    ('TEST-N17', 'Dawret in-Nawfraġju (punto de prueba)',        'Xemxija',        35.951015, 14.388060),
    ('TEST-N18', 'Triq San Pawl (punto de prueba)',              'Mġarr',          35.920589, 14.366501),
    ('TEST-N19', 'Triq Lazzaru Pisani (punto de prueba)',        'Mġarr',          35.918884, 14.364119),
    ('TEST-N20', 'Triq San Pietru (punto de prueba)',            'Mġarr',          35.921455, 14.368541)
  ) as t(codigo, direccion, pueblo, lat, lng)
  loop
    update public.propiedades p
       set direccion = r.direccion || ', ' || r.pueblo, lat = r.lat, lng = r.lng,
           coord_estado = 'confirmada', coord_fuente = 'tomtom', coord_motivo = null,
           coord_info = jsonb_build_object('prueba', true, 'origen', 'calle pública (TomTom), sin número'),
           pueblo_tomtom = null, coord_confirmada_por = null, coord_confirmada_en = now()
     where p.codigo = r.codigo and p.es_prueba;
    if found then
      n := n + 1;
      insert into public.eventos (quien, que, propiedad_id)
      select null, 'punto de prueba real (calle pública) confirmado', id from public.propiedades where codigo = r.codigo;
    end if;
  end loop;
  perform set_config('opsflow.coord', '', true);
  raise notice 'Puntos de prueba guardados: %', n;
end $$;

select codigo, pueblo, direccion, round(lat::numeric, 5) as lat, round(lng::numeric, 5) as lng, coord_estado
from public.propiedades where codigo like 'TEST-N%' and es_prueba order by codigo;


-- ═══════════════ 30-PEGAR-equipos.sql ═══════════════
-- OpsFlow · equipos de limpieza: 2–3 personas en el mismo apartamento, cada una con su cuenta (12 oct 2026)
-- SPEC-equipos.md (aprobado). Ejecutar DESPUES de 027. Se puede ejecutar varias veces. Todo UPDATE/DELETE lleva WHERE.
--   · La líder forma equipos (2–3 cleaners). Se asigna al equipo: todos ven los mismos apartamentos.
--   · Cada sala es de quien marca primero un paso en ella; los demás la ven bloqueada. "final" es común.
--   · Quien llega escanea el QR (o "I'm here"): queda registrado. Un cleaner sin equipo funciona igual que hoy.
--   · limpiezas.asignada_a se mantiene (= responsable del equipo) para no romper nada de lo anterior.

-- 1. Tablas ---------------------------------------------------------------------------------
create table if not exists public.equipos (
  id           uuid primary key default gen_random_uuid(),
  responsable  uuid not null references public.perfiles(id),
  activo       boolean not null default true,
  creado_por   uuid, creado_en timestamptz not null default now(), deshecho_en timestamptz
);
create table if not exists public.equipo_miembros (
  equipo_id    uuid not null references public.equipos(id) on delete cascade,
  perfil_id    uuid not null references public.perfiles(id),
  desde        timestamptz not null default now(),
  hasta        timestamptz,
  primary key (equipo_id, perfil_id)
);
-- Un cleaner solo puede estar en un equipo activo
create unique index if not exists equipo_miembros_uno on public.equipo_miembros (perfil_id) where hasta is null;

-- Quiénes forman el equipo de cada limpieza (foto fija al asignar; no cambia cuando ya empezó)
create table if not exists public.limpieza_miembros (
  limpieza_id  uuid not null references public.limpiezas(id) on delete cascade,
  perfil_id    uuid not null references public.perfiles(id),
  primary key (limpieza_id, perfil_id)
);
-- Quién llegó al apartamento (con QR o "I'm here") y cuándo
create table if not exists public.limpieza_personas (
  limpieza_id  uuid not null references public.limpiezas(id) on delete cascade,
  perfil_id    uuid not null references public.perfiles(id),
  llegada_en   timestamptz not null default now(),
  llegada_qr   boolean not null default false,
  gps          jsonb,
  primary key (limpieza_id, perfil_id)
);
-- Quién lleva cada sala (la clave garantiza UN solo dueño por sala)
create table if not exists public.limpieza_salas (
  limpieza_id  uuid not null references public.limpiezas(id) on delete cascade,
  sala         text not null check (sala in ('kitchen', 'bathroom', 'bedroom', 'living')),
  perfil_id    uuid not null references public.perfiles(id),
  desde        timestamptz not null default now(),
  terminada_en timestamptz,
  primary key (limpieza_id, sala)
);

do $$ declare t text; begin
  foreach t in array array['equipos', 'equipo_miembros', 'limpieza_miembros', 'limpieza_personas', 'limpieza_salas'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
  end loop;
end $$;
-- Lectura: los líderes de limpieza y Operación todo; cada cleaner lo de sus limpiezas y su equipo
drop policy if exists "equipos: lectura" on public.equipos;
create policy "equipos: lectura" on public.equipos for select to authenticated using (
  ((select public.mi_nivel()) = 'operacion' or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza'))
  or exists (select 1 from public.equipo_miembros m where m.equipo_id = equipos.id and m.perfil_id = (select auth.uid())));
drop policy if exists "equipo_miembros: lectura" on public.equipo_miembros;
create policy "equipo_miembros: lectura" on public.equipo_miembros for select to authenticated using (
  ((select public.mi_nivel()) = 'operacion' or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza')) or perfil_id = (select auth.uid()));

-- 2. Ayudantes ------------------------------------------------------------------------------
-- Miembros de una limpieza: la foto fija + el responsable (asignada_a), por si es una limpieza antigua
create or replace function public._miembros_de(p_l uuid)
returns uuid[] language sql stable security definer set search_path = ''
as $$
  select coalesce(array(
    select m.perfil_id from public.limpieza_miembros m where m.limpieza_id = p_l
    union select l.asignada_a from public.limpiezas l where l.id = p_l and l.asignada_a is not null), '{}')
$$;
create or replace function public._soy_miembro(p_l uuid)
returns boolean language sql stable security definer set search_path = ''
as $$ select (select auth.uid()) = any(public._miembros_de(p_l)) $$;
revoke execute on function public._miembros_de(uuid) from public, anon, authenticated;
revoke execute on function public._soy_miembro(uuid) from public, anon;
grant  execute on function public._soy_miembro(uuid) to authenticated;   -- lo usan las reglas de lectura

-- "Ana + Luis": el equipo activo de una persona (el responsable primero) o su nombre si va sola
create or replace function public._equipo_txt(p_perfil uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select string_agg(p.nombre, ' + ' order by (p.id = e.responsable) desc, p.nombre)
    from public.equipo_miembros m0 join public.equipos e on e.id = m0.equipo_id and e.activo
    join public.equipo_miembros m on m.equipo_id = e.id and m.hasta is null
    join public.perfiles p on p.id = m.perfil_id
    where m0.perfil_id = p_perfil and m0.hasta is null),
    (select nombre from public.perfiles where id = p_perfil))
$$;
-- Los nombres del equipo de UNA limpieza (de su foto fija)
create or replace function public._equipo_limpieza_txt(p_l uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select string_agg(p.nombre, ' + ' order by (p.id = l.asignada_a) desc, p.nombre)
  from public.limpiezas l join public.perfiles p on p.id = any(public._miembros_de(l.id))
  where l.id = p_l
$$;
revoke execute on function public._equipo_txt(uuid), public._equipo_limpieza_txt(uuid) from public, anon, authenticated;

-- Rehacer la foto fija de una limpieza que aún no ha empezado: el equipo activo del responsable (o él solo)
create or replace function public._rehacer_miembros(p_l uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_asig uuid;
begin
  select asignada_a into v_asig from public.limpiezas where id = p_l;
  delete from public.limpieza_miembros where limpieza_id = p_l;
  if v_asig is null then return; end if;
  insert into public.limpieza_miembros (limpieza_id, perfil_id)
  select p_l, m.perfil_id from public.equipo_miembros m0
    join public.equipos e on e.id = m0.equipo_id and e.activo
    join public.equipo_miembros m on m.equipo_id = e.id and m.hasta is null
   where m0.perfil_id = v_asig and m0.hasta is null
  union select p_l, v_asig
  on conflict do nothing;
end $$;
-- El responsable del equipo activo de una persona (o ella misma)
create or replace function public._responsable(p_perfil uuid)
returns uuid language sql stable security definer set search_path = ''
as $$
  select coalesce((select e.responsable from public.equipo_miembros m join public.equipos e on e.id = m.equipo_id and e.activo
                   where m.perfil_id = p_perfil and m.hasta is null), p_perfil)
$$;
revoke execute on function public._rehacer_miembros(uuid), public._responsable(uuid) from public, anon, authenticated;

-- Las limpiezas que aún no han empezado de estas personas: pasan al responsable de su equipo y se rehace la foto fija
create or replace function public._reajustar(p_personas uuid[])
returns void language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  for r in select l.id, l.asignada_a from public.limpiezas l
            where l.estado = 'asignada' and l.fecha >= (now() at time zone 'Europe/Malta')::date
              and (l.asignada_a = any(p_personas)
                   or exists (select 1 from public.limpieza_miembros m where m.limpieza_id = l.id and m.perfil_id = any(p_personas)))
  loop
    update public.limpiezas set asignada_a = public._responsable(r.asignada_a) where id = r.id and asignada_a is distinct from public._responsable(r.asignada_a);
    perform public._rehacer_miembros(r.id);
  end loop;
end $$;
revoke execute on function public._reajustar(uuid[]) from public, anon, authenticated;

-- Las limpiezas que ya existen: su foto fija es su cleaner
insert into public.limpieza_miembros (limpieza_id, perfil_id)
select id, asignada_a from public.limpiezas where asignada_a is not null
on conflict do nothing;

-- ¿Ha llegado esta persona? (las limpiezas empezadas antes de este cambio no tienen llegadas: vale su cleaner)
create or replace function public._presente(p_l uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.limpieza_personas where limpieza_id = p_l and perfil_id = (select auth.uid()))
      or (not exists (select 1 from public.limpieza_personas where limpieza_id = p_l)
          and (select asignada_a from public.limpiezas where id = p_l) = (select auth.uid()))
$$;
-- Tomar una sala (si está libre) o fallar si es de otra persona
create or replace function public._tomar_sala(p_l uuid, p_sala text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_duen uuid; v_nom text;
begin
  if p_sala not in ('kitchen', 'bathroom', 'bedroom', 'living') then return; end if;
  if not public._presente(p_l) then raise exception 'Scan the QR when you arrive (or tap "I''m here") first.'; end if;
  insert into public.limpieza_salas (limpieza_id, sala, perfil_id) values (p_l, p_sala, (select auth.uid()))
  on conflict (limpieza_id, sala) do nothing;
  select perfil_id into v_duen from public.limpieza_salas where limpieza_id = p_l and sala = p_sala;
  if v_duen is distinct from (select auth.uid()) then
    select nombre into v_nom from public.perfiles where id = v_duen;
    raise exception '% already has the %.', split_part(v_nom, ' ', 1),
      case p_sala when 'kitchen' then 'kitchen' when 'bathroom' then 'bathroom' when 'bedroom' then 'bedroom' else 'living room' end;
  end if;
end $$;
-- Sala terminada = todos sus pasos obligatorios hechos
create or replace function public._revisar_sala(p_l uuid, p_sala text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_faltan int;
begin
  select * into v from public.limpiezas where id = p_l;
  select count(*) into v_faltan from public.checklist_pasos p
   where p.tipo = v.tipo and p.activo and p.obligatorio and p.sala = p_sala and not (v.checklist ? p.id::text);
  update public.limpieza_salas set terminada_en = case when v_faltan = 0 then coalesce(terminada_en, now()) end
   where limpieza_id = p_l and sala = p_sala;
end $$;
revoke execute on function public._presente(uuid), public._tomar_sala(uuid, text), public._revisar_sala(uuid, text) from public, anon, authenticated;

-- Al empezar una limpieza, quien la empieza queda como "llegado"
create or replace function public._limpieza_inicio()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is not null then
    insert into public.limpieza_personas (limpieza_id, perfil_id, llegada_en, llegada_qr, gps)
    values (new.id, (select auth.uid()), now(), coalesce(new.inicio_qr, false), new.gps->'inicio')
    on conflict do nothing;
  end if;
  return new;
end $$;
revoke execute on function public._limpieza_inicio() from public, anon, authenticated;
drop trigger if exists limpiezas_inicio on public.limpiezas;
create trigger limpiezas_inicio after update of estado on public.limpiezas
for each row when (old.estado = 'asignada' and new.estado = 'en_curso') execute function public._limpieza_inicio();

-- 3. Quién ve qué (lo de antes, pero "mía" = soy del equipo de esa limpieza) --------------------
drop policy if exists "limpiezas: lectura por rol" on public.limpiezas;
create policy "limpiezas: lectura por rol" on public.limpiezas for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) in ('Limpieza', 'Drivers'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and publicada and public._soy_miembro(id))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and publicada and zona = (select public.mi_zona()))
);
drop policy if exists "pendientes: lectura por rol" on public.pendientes;
create policy "pendientes: lectura por rol" on public.pendientes for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Linens' and tipo::text = 'linens')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Bodega' and tipo::text = 'utiles')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Drivers' and tipo::text in ('linens', 'recogida', 'utiles'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and public._soy_miembro(limpieza_id))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and (tipo::text = 'recogida' or (tipo::text in ('linens', 'utiles') and estado <> 'abierto')))
);
drop policy if exists "bolsas: lectura" on public.bolsas;
create policy "bolsas: lectura" on public.bolsas for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) in ('Linens', 'Drivers', 'Limpieza'))
  or ((select public.mi_departamento()) = 'Drivers' and (select public.mi_nivel()) = 'operador')
  or public._soy_miembro(limpieza_id)
);

-- 4. Funciones de siempre que ahora miran el equipo ------------------------------------------------
create or replace function public._mi_limpieza(p_id uuid)
returns public.limpiezas language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id for update;
  if not found or not public._soy_miembro(p_id) or not v.publicada or public.mi_nivel() is null then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return v;
end $$;
revoke execute on function public._mi_limpieza(uuid) from public, anon, authenticated;

create or replace function public._puede_subir_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and public._soy_miembro(l.id) and l.publicada and l.estado = 'en_curso'
      and public.mi_nivel() is not null)
  or (split_part(p_nombre, '/', 2) = 'bolsa.jpg' and exists (
    select 1 from public.bolsas b
    where b.limpieza_id::text = split_part(p_nombre, '/', 1) and b.driver = (select auth.uid()) and b.estado = 'en_camion'))
$$;
create or replace function public._puede_ver_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select public._lider_limpieza()
  or exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1) and public._soy_miembro(l.id) and public.mi_nivel() is not null)
  or (split_part(p_nombre, '/', 2) = 'basura.jpg' and public.mi_departamento() = 'Drivers' and exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and (public.mi_nivel() = 'lider' or l.zona = public.mi_zona())))
  or (split_part(p_nombre, '/', 2) = 'bolsa.jpg' and (public.mi_departamento() in ('Drivers', 'Linens')))
$$;
revoke execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) from public, anon;
grant  execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) to authenticated;

create or replace function public.marcar_recibido(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  if not public._soy_miembro(v.limpieza_id) or public.mi_nivel() is null then
    raise exception 'Solo el equipo de esta limpieza puede marcar recibido.';
  end if;
  if v.tipo <> 'linens' or v.estado <> 'entregado' then raise exception 'Todavía no se ha entregado.'; end if;
  update public.pendientes set estado = 'cerrado', cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
  perform public._evento('recibido por cleaner: cerrado', v.limpieza_id, p_id);
end $$;

create or replace function public.reportar_pendiente(p_limpieza uuid, p_tipo public.tipo_pendiente, p_detalle text, p_cantidad int default 1)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_prio boolean; v_id uuid;
begin
  select * into v from public.limpiezas where id = p_limpieza;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if not public._lider_limpieza() and (not public._soy_miembro(v.id) or not v.publicada) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  if v.estado not in ('en_curso', 'terminada') then raise exception 'Primero hay que empezar la limpieza.'; end if;
  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba)
  values (v.id, v.propiedad_id, v.zona, v.fecha, p_tipo,
          coalesce(nullif(btrim(p_detalle), ''), case when p_tipo = 'recogida' then 'Basura y linens sucios' end),
          coalesce(p_cantidad, 1), coalesce(v_prio, false), (select auth.uid()), v.es_prueba)
  returning id into v_id;
  perform public._evento('pendiente reportado (' || p_tipo || ')', v.id, v_id);
  return v_id;
end $$;

-- Asignar: a una persona o a su equipo (se guarda el responsable y la foto fija del equipo)
create or replace function public.asignar_limpieza(p_id uuid, p_cleaner uuid, p_orden int, p_tipo public.tipo_limpieza)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_resp uuid;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación asignan limpiezas.'; end if;
  select * into v from public.limpiezas where id = p_id for update;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if v.estado not in ('sin_asignar', 'asignada') then raise exception 'Esa limpieza ya empezó: no se puede reasignar.'; end if;
  if p_cleaner is not null and not exists (
       select 1 from public.perfiles where id = p_cleaner and activo and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception 'Solo se puede asignar a un cleaner activo.';
  end if;
  v_resp := case when p_cleaner is null then null else public._responsable(p_cleaner) end;
  update public.limpiezas
     set asignada_a = v_resp, orden = p_orden, tipo = coalesce(p_tipo, tipo),
         estado = case when v_resp is null then 'sin_asignar' else 'asignada' end::public.estado_limpieza,
         publicada = case when v_resp is null then false else publicada end
   where id = p_id;
  perform public._rehacer_miembros(p_id);
  perform public._evento('asignada' || coalesce(' a ' || public._equipo_txt(v_resp), ''), p_id, null);
end $$;

-- Marcar un paso: la sala pasa a ser de quien marca (si está libre); si es de otra persona, no se puede
create or replace function public.marcar_paso(p_id uuid, p_paso int, p_hecho boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_sala text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  select sala into v_sala from public.checklist_pasos where id = p_paso and tipo = v.tipo and activo;
  if not found then raise exception 'Ese paso no es de esta limpieza.'; end if;
  if not public._presente(p_id) then raise exception 'Scan the QR when you arrive (or tap "I''m here") first.'; end if;
  perform public._tomar_sala(p_id, v_sala);
  update public.limpiezas
     set checklist = case when p_hecho then checklist || jsonb_build_object(p_paso::text, now())
                          else checklist - p_paso::text end
   where id = p_id;
  perform public._revisar_sala(p_id, v_sala);
end $$;

-- Foto de cierre: la de cada sala la hace quien la lleva (la de la basura, cualquiera)
create or replace function public.registrar_foto(p_id uuid, p_sala text, p_ruta text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  if p_sala not in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura') then raise exception 'Sala no válida.'; end if;
  if split_part(p_ruta, '/', 1) <> p_id::text then raise exception 'La foto no es de esta limpieza.'; end if;
  perform public._tomar_sala(p_id, p_sala);
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por)
  values (p_id, p_sala, p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
end $$;

-- 5. Nuevo para el equipo ----------------------------------------------------------------------
-- Llegar al apartamento ya empezado por un compañero: con el QR (o sin él: "I'm here")
create or replace function public.llegar_limpieza(p_id uuid, p_qr text default null,
  p_lat double precision default null, p_lng double precision default null, p_prec double precision default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_token text; v_cod text; n int;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'This cleaning has not started yet: scan the QR to start it.'; end if;
  select qr_token, codigo into v_token, v_cod from public.propiedades where id = v.propiedad_id;
  if p_qr is not null and coalesce(regexp_replace(btrim(p_qr), '^OPSFLOW:', ''), '') <> v_token then
    raise exception 'This QR is not for %.', v_cod;
  end if;
  insert into public.limpieza_personas (limpieza_id, perfil_id, llegada_qr, gps)
  values (p_id, (select auth.uid()), p_qr is not null, public._gps(v.propiedad_id, p_lat, p_lng, p_prec))
  on conflict (limpieza_id, perfil_id) do nothing;
  select count(*) into n from public.limpieza_personas where limpieza_id = p_id;
  update public.limpiezas set personas = greatest(personas, least(n, 4)) where id = p_id;
  perform public._evento('llegó ' || (select nombre from public.perfiles where id = (select auth.uid()))
                         || case when p_qr is null then ' (sin QR)' else ' (QR)' end, p_id, null);
end $$;

-- Soltar una sala: quien la lleva (si no la ha terminado) o la líder de limpieza / Operación
create or replace function public.soltar_sala(p_id uuid, p_sala text)
returns void language plpgsql security definer set search_path = ''
as $$
declare s public.limpieza_salas;
begin
  select * into s from public.limpieza_salas where limpieza_id = p_id and sala = p_sala for update;
  if not found then raise exception 'Nobody has that room.'; end if;
  if not public._lider_limpieza() then
    perform public._mi_limpieza(p_id);
    if s.perfil_id is distinct from (select auth.uid()) then raise exception 'Only who has the room (or the leader) can release it.'; end if;
    if s.terminada_en is not null then raise exception 'That room is finished: ask your leader.'; end if;
  end if;
  delete from public.limpieza_salas where limpieza_id = p_id and sala = p_sala;
  perform public._evento('sala soltada: ' || p_sala || ' (era de ' || (select nombre from public.perfiles where id = s.perfil_id) || ')', p_id, null);
end $$;

-- Equipos activos (pantalla de Asignar)
create or replace function public.equipos_activos()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo la líder de limpieza u Operación.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'responsable', e.responsable, 'nombre', public._equipo_txt(e.responsable),
      'miembros', (select jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre) order by (p.id = e.responsable) desc, p.nombre)
                   from public.equipo_miembros m join public.perfiles p on p.id = m.perfil_id where m.equipo_id = e.id and m.hasta is null),
      'desde', e.creado_en) order by public._equipo_txt(e.responsable))
    from public.equipos e where e.activo), '[]'::jsonb);
end $$;

-- Formar un equipo (2–3 cleaners). Quien ya estaba en otro equipo sale de él. Lo que aún no ha empezado pasa al equipo.
create or replace function public.guardar_equipo(p_miembros uuid[])
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_viejos uuid[]; e record;
begin
  if not public._lider_limpieza() then raise exception 'Solo la líder de limpieza u Operación forman equipos.'; end if;
  p_miembros := array(select distinct x from unnest(p_miembros) x where x is not null);
  if cardinality(p_miembros) not between 2 and 3 then raise exception 'Un equipo es de 2 o 3 cleaners.'; end if;
  if exists (select 1 from unnest(p_miembros) x where not exists (
       select 1 from public.perfiles where id = x and activo and departamento = 'Limpieza' and nivel = 'operador')) then
    raise exception 'Solo cleaners activos.';
  end if;
  -- Sacar a estas personas de sus equipos anteriores (un equipo que se queda con 1 persona se deshace)
  v_viejos := array(select distinct m.equipo_id from public.equipo_miembros m where m.perfil_id = any(p_miembros) and m.hasta is null);
  update public.equipo_miembros set hasta = now() where perfil_id = any(p_miembros) and hasta is null;
  for e in select x as id from unnest(v_viejos) x loop
    if (select count(*) from public.equipo_miembros where equipo_id = e.id and hasta is null) < 2 then
      update public.equipo_miembros set hasta = now() where equipo_id = e.id and hasta is null;
      update public.equipos set activo = false, deshecho_en = now() where id = e.id;
    elsif not exists (select 1 from public.equipo_miembros m join public.equipos q on q.id = m.equipo_id
                      where m.equipo_id = e.id and m.perfil_id = q.responsable and m.hasta is null) then
      update public.equipos set responsable = (select perfil_id from public.equipo_miembros where equipo_id = e.id and hasta is null limit 1) where id = e.id;
    end if;
  end loop;
  insert into public.equipos (responsable, creado_por) values (p_miembros[1], (select auth.uid())) returning id into v_id;
  insert into public.equipo_miembros (equipo_id, perfil_id) select v_id, x from unnest(p_miembros) x;
  perform public._reajustar(p_miembros || coalesce((select array_agg(m.perfil_id) from public.equipo_miembros m where m.equipo_id = any(v_viejos)), '{}'));
  insert into public.eventos (quien, que) values ((select auth.uid()), 'equipo formado: ' || public._equipo_txt(p_miembros[1]));
  return v_id;
end $$;

-- Deshacer un equipo: cada uno vuelve a ir solo; lo que no ha empezado se queda con el responsable
create or replace function public.deshacer_equipo(p_equipo uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_nom text; v_m uuid[];
begin
  if not public._lider_limpieza() then raise exception 'Solo la líder de limpieza u Operación.'; end if;
  select public._equipo_txt(responsable) into v_nom from public.equipos where id = p_equipo and activo;
  if v_nom is null then raise exception 'Ese equipo no existe o ya se deshizo.'; end if;
  v_m := array(select perfil_id from public.equipo_miembros where equipo_id = p_equipo and hasta is null);
  update public.equipo_miembros set hasta = now() where equipo_id = p_equipo and hasta is null;
  update public.equipos set activo = false, deshecho_en = now() where id = p_equipo;
  perform public._reajustar(v_m);
  insert into public.eventos (quien, que) values ((select auth.uid()), 'equipo deshecho: ' || v_nom);
end $$;

-- Checklist (cleaner del equipo o líder): + salas con su dueño, quién llegó y si yo llegué
create or replace function public.mi_checklist(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id;
  if not found or public.mi_nivel() is null
     or not (public._lider_limpieza() or (public._soy_miembro(p_id) and v.publicada)) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return jsonb_build_object(
    'inicio_qr', v.inicio_qr, 'fin_qr', v.fin_qr, 'linens_revisado', v.linens_revisado, 'cierre', v.cierre, 'personas', v.personas, 'estado', v.estado,
    'pasos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sala', p.sala, 'en', p.texto_en, 'es', p.texto_es,
                          'obligatorio', p.obligatorio, 'hecho', v.checklist ? p.id::text) order by p.orden)
                       from public.checklist_pasos p where p.tipo = v.tipo and p.activo), '[]'::jsonb),
    'fotos', coalesce((select jsonb_object_agg(f.sala, f.ruta) from public.fotos_cierre f where f.limpieza_id = p_id), '{}'::jsonb),
    'salas', coalesce((select jsonb_object_agg(s.sala, jsonb_build_object('nombre', split_part(pf.nombre, ' ', 1), 'mio', s.perfil_id = (select auth.uid()),
                          'desde', s.desde, 'terminada', s.terminada_en is not null))
                       from public.limpieza_salas s join public.perfiles pf on pf.id = s.perfil_id where s.limpieza_id = p_id), '{}'::jsonb),
    'equipo', (select jsonb_agg(jsonb_build_object('nombre', pf.nombre, 'yo', pf.id = (select auth.uid()),
                  'llegada', to_char(lp.llegada_en at time zone 'Europe/Malta', 'HH24:MI'), 'qr', lp.llegada_qr)
                  order by lp.llegada_en nulls last, pf.nombre)
               from public.perfiles pf left join public.limpieza_personas lp on lp.limpieza_id = p_id and lp.perfil_id = pf.id
               where pf.id = any(public._miembros_de(p_id))),
    'presente', public._presente(p_id));
end $$;

-- Seguimiento (líder de limpieza / Operación): equipo, quién llegó y quién lleva cada sala, por limpieza del día
create or replace function public.salas_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo la líder de limpieza u Operación.'; end if;
  return coalesce((select jsonb_object_agg(l.id, jsonb_build_object(
      'equipo', public._equipo_limpieza_txt(l.id),
      'n', cardinality(public._miembros_de(l.id)),
      'llegadas', (select jsonb_agg(jsonb_build_object('nombre', split_part(pf.nombre, ' ', 1), 'en', to_char(lp.llegada_en at time zone 'Europe/Malta', 'HH24:MI'), 'qr', lp.llegada_qr) order by lp.llegada_en)
                   from public.limpieza_personas lp join public.perfiles pf on pf.id = lp.perfil_id where lp.limpieza_id = l.id),
      'salas', (select jsonb_agg(jsonb_build_object('sala', s.sala, 'nombre', split_part(pf.nombre, ' ', 1), 'desde', s.desde, 'terminada_en', s.terminada_en)
                   order by s.desde)
                from public.limpieza_salas s join public.perfiles pf on pf.id = s.perfil_id where s.limpieza_id = l.id)))
    from public.limpiezas l where l.fecha = p_fecha and l.asignada_a is not null), '{}'::jsonb);
end $$;

-- Tiempos por sala (líder de limpieza / Operación): media de minutos de cada sala en cada apartamento
create or replace function public.tiempos_salas(p_dias int default 90)
returns table (codigo text, nombre text, sala text, veces bigint, media_min int)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación.'; end if;
  return query
  select p.codigo, p.nombre, s.sala, count(*), round(avg(extract(epoch from (s.terminada_en - s.desde)) / 60))::int
  from public.limpieza_salas s join public.limpiezas l on l.id = s.limpieza_id join public.propiedades p on p.id = l.propiedad_id
  where s.terminada_en is not null and l.fecha >= (now() at time zone 'Europe/Malta')::date - p_dias
    and s.terminada_en - s.desde between interval '2 minutes' and interval '4 hours'
  group by p.codigo, p.nombre, s.sala
  order by p.codigo, s.sala;
end $$;

-- 6. Pantallas que muestran el nombre del equipo ------------------------------------------------
-- Día del cleaner: lo de su equipo, con quién va y si ya llegó
create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden,
      'con', (select string_agg(split_part(pf.nombre, ' ', 1), ', ' order by pf.nombre) from public.perfiles pf
              where pf.id = any(public._miembros_de(l.id)) and pf.id <> (select auth.uid())),
      'presente', public._presente(l.id), 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar, 'linens_revisado', l.linens_revisado,
      'bolsa', (select jsonb_build_object('estado', b.estado, 'entregada_en', to_char(b.entregada_en at time zone 'Europe/Malta', 'HH24:MI'), 'comentario', b.comentario) from public.bolsas b where b.limpieza_id = l.id),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado, 'items', pe.items,
                     'listo_a', to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI'), 'listo_creado', case when pe.listo_a is not null then pe.creado_en end) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and public._soy_miembro(l.id) and l.estado::text <> 'cancelada'
      and public.mi_nivel() is not null
  ) t
$$;

create or replace function public.mi_ruta(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_zona public.zona := public.mi_zona();
begin
  if not (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers') then
    raise exception 'Esta pantalla es para drivers.';
  end if;
  return jsonb_build_object(
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'estado', pe.estado,
        'prioritario', pe.prioritario, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'foto', pe.foto, 'items', pe.items, 'incidencia', pe.incidencia)
        order by pe.prioritario desc, c.hora_entrada nulls last, pe.creado_en)
      from public.pendientes pe
      join public.limpiezas l on l.id = pe.limpieza_id
      join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.fecha = p_fecha and pe.zona = v_zona
        and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto'))), '[]'::jsonb),
    'orden', coalesce((select jsonb_agg(jsonb_build_object(
        'cleaner', public._equipo_limpieza_txt(l.id), 'orden', l.orden, 'estado', l.estado, 'codigo', p.codigo, 'nombre', p.nombre,
        'pueblo', p.pueblo, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by public._equipo_limpieza_txt(l.id), l.orden)
      from public.limpiezas l
      join public.propiedades p on p.id = l.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada and l.estado::text <> 'cancelada'), '[]'::jsonb));
end $$;

create or replace function public.entradas_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public._lider_limpieza() or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo los líderes u Operación.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('cleaner', p.id, 'nombre', public._equipo_txt(p.id), 'zona', p.zona,
      'hora', to_char(public._hora_entrada(p_fecha, p.id), 'HH24:MI'),
      'fijada', exists (select 1 from public.entradas_equipo e where e.fecha = p_fecha and e.cleaner = p.id),
      'limpiezas', (select count(*) from public.limpiezas l where l.fecha = p_fecha and l.asignada_a = p.id and l.estado::text <> 'cancelada'))
      order by public._equipo_txt(p.id))
    from public.perfiles p
    where exists (select 1 from public.limpiezas l where l.fecha = p_fecha and l.asignada_a = p.id and l.estado::text <> 'cancelada')), '[]'::jsonb);
end $$;

create or replace function public.tablero_zonas()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'zona', (x->>'prioridad')::int desc, x->>'entrada' nulls last, x->>'desde') from (
    select jsonb_build_object(
      'id', pe.id, 'zona', pe.zona, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'items', pe.items,
      'foto', pe.foto, 'incidencia', pe.incidencia, 'fecha', pe.fecha,
      'desde', coalesce(pe.preparado_en, pe.creado_en),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end,
      'prioridad', case when c.fecha = v_hoy and c.hora_entrada is not null then 1 else 0 end,
      'tomado_por', t.nombre, 'equipo', public._equipo_limpieza_txt(l.id),
      'listo_a', to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI'), 'terminada', l.estado = 'terminada',
      'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end, 'coord', p.coord_estado, 'mio', pe.tomado_por = (select auth.uid()), 'asignado', pe.asignado_por is not null) as x
    from public.pendientes pe
    join public.propiedades p on p.id = pe.propiedad_id
    join public.limpiezas l on l.id = pe.limpieza_id
    join public.checkouts c on c.id = l.checkout_id
    left join public.perfiles t on t.id = pe.tomado_por
    where public._en_driver(pe) and pe.fecha >= v_hoy - 7) s), '[]'::jsonb);
end $$;

-- Avisos: lo que era para "su cleaner" ahora es para cada miembro del equipo
create or replace function public.avisos_para(p_tipo text, p_id uuid default null, p_fecha date default null)
returns table (perfil_id uuid, titulo text, cuerpo text, url text, clave text, telefonos jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  pe public.pendientes; li public.limpiezas; pr public.propiedades; ck public.checkouts;
  v_aviso text; v_ok boolean := true;
begin
  create temp table if not exists _dest (perfil_id uuid, idioma text, t_es text, t_en text, c_es text, c_en text, url text, clave text) on commit drop;
  truncate _dest;

  if p_tipo = 'pendiente' then
    select * into pe from public.pendientes where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = pe.propiedad_id;
    select c.* into ck from public.checkouts c join public.limpiezas l on l.checkout_id = c.id where l.id = pe.limpieza_id;
    v_aviso := 'pendiente:' || pe.id || ':' || pe.estado;

    if pe.asignado_por is not null and pe.tomado_por is not null and pe.tomado_en > now() - interval '2 minutes' then
      -- 14. El líder asigna una tarea a un driver concreto → ese driver
      insert into _dest select p.id, p.idioma,
        'Asignado a ti: ' || pr.codigo, 'Assigned to you: ' || pr.codigo,
        pr.pueblo || ' · ' || case when pe.tipo = 'recogida' then 'recoger' else 'entregar' end,
        pr.pueblo || ' · ' || case when pe.tipo = 'recogida' then 'pick up' else 'deliver' end,
        './', 'pendiente:' || pe.id || ':asignado:' || extract(epoch from pe.tomado_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = pe.tomado_por;

    elsif pe.incidencia is not null and pe.incidencia_en > now() - interval '2 minutes'
       and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto')) then
      -- 11. El driver no pudo entregar/recoger → lider de drivers
      insert into _dest select p.id, p.idioma,
        'No se pudo entregar: ' || pr.codigo, 'Couldn''t deliver: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.incidencia, pr.pueblo || ' · ' || pe.incidencia,
        './?v=drivers', 'pendiente:' || pe.id || ':incidencia:' || extract(epoch from pe.incidencia_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Drivers'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Deliver: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.listo_a is not null then
      -- 15. El cleaner avisa "listo en 30 min" → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Listo a las ' || to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI') || ': ' || pr.codigo,
        'Ready at ' || to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI') || ': ' || pr.codigo,
        pr.pueblo || ' · recoger basura y linens sucios', pr.pueblo || ' · pick up trash & dirty linens',
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.foto is not null then
      -- 4b. Basura dejada en el apto (con foto) → drivers de la zona y lider de drivers
      insert into _dest select p.id, p.idioma,
        'Basura en el apto: ' || pr.codigo, 'Trash left: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.detalle, pr.pueblo || ' · pick it up (photo in the app)',
        './', null
      from public.perfiles p where p.activo and p.departamento = 'Drivers'
        and ((p.nivel = 'operador' and p.zona = pe.zona) or (p.nivel = 'lider' and (p.zona is null or p.zona = pe.zona)));

    elsif pe.tipo::text = 'utiles' and pe.estado = 'abierto' then
      -- 8. Faltan utiles → lider de bodega
      insert into _dest select p.id, p.idioma,
        'Útiles: ' || pe.detalle, 'Tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=bodega', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Bodega'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo::text = 'utiles' and pe.estado = 'preparado' then
      -- 9. Utiles preparados → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar útiles: ' || pe.detalle, 'Deliver tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' then
      -- 4. Recogida → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Recoger: basura y linens sucios', 'Pick up: trash & dirty linens',
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'linens' and pe.estado = 'entregado' then
      -- 5. Entregado → el cleaner que lo pidio
      insert into _dest select p.id, p.idioma,
        'Entregado: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Delivered: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=seguimiento', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en where true;  -- Supabase exige WHERE en todo UPDATE
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    if li.estado = 'terminada' and li.cierre->>'llaves' = 'false' then
      -- 10. Llaves NO dejadas en el key box → lider de limpieza y lider de drivers (urgente)
      insert into _dest select p.id, p.idioma,
        '⚠ Llaves NO en el key box: ' || pr.codigo, '⚠ Keys NOT in the key box: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''), pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''),
        case when p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, 'limpieza:' || li.id || ':llaves:' || p.id
      from public.perfiles p
      where p.activo and p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona);
      v_aviso := 'limpieza:' || li.id || ':llaves';
    elsif li.estado::text = 'cancelada' and li.publicada then
      -- 12. Limpieza cancelada → su cleaner
      insert into _dest select p.id, p.idioma,
        'Cancelada: ' || pr.codigo, 'Cancelled: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''), pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''),
        './', 'limpieza:' || li.id || ':cancelada:' || p.id
      from public.perfiles p where p.activo and p.id = any(public._miembros_de(li.id));
      v_aviso := 'limpieza:' || li.id || ':cancelada';
    elsif li.estado = 'asignada' and li.publicada and li.reabierta_en > now() - interval '2 minutes' then
      -- 13. Limpieza reabierta (tras "no pude entrar") → su cleaner
      insert into _dest select p.id, p.idioma,
        'Reabierta: ' || pr.codigo, 'Reopened: ' || pr.codigo,
        pr.pueblo || ' · vuelve a tu lista', pr.pueblo || ' · back on your list',
        './', 'limpieza:' || li.id || ':reabierta:' || extract(epoch from li.reabierta_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = any(public._miembros_de(li.id));
      v_aviso := 'limpieza:' || li.id || ':reabierta';
    elsif li.estado <> 'no_pude_entrar' then
      return;
    else
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));
    end if;

  elsif p_tipo = 'orden' then
    if p_fecha is null then return; end if;
    -- 1. Orden publicado → cada cleaner con limpiezas publicadas ese dia
    --    (la clave lleva cuantas tiene: si el lider le anade otra y publica, le vuelve a sonar)
    insert into _dest select p.id, p.idioma,
      'Orden de limpieza listo', 'Your cleaning order is ready',
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartamento' || case when count(*) > 1 then 's' else '' end,
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartment' || case when count(*) > 1 then 's' else '' end,
      './', 'orden:' || p_fecha || ':' || p.id || ':' || count(*)
    from public.limpiezas l join public.perfiles p on p.id = any(public._miembros_de(l.id))
    where l.fecha = p_fecha and l.publicada and p.activo
    group by p.id, p.idioma;

  else
    return;
  end if;

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id) where true;

  -- Apuntar los nuevos; los que ya estaban apuntados no salen otra vez
  return query
  with nuevos as (
    insert into public.avisos_enviados (clave, perfil_id, titulo)
    select d.clave, d.perfil_id, case when d.idioma = 'es' then d.t_es else d.t_en end from _dest d
    on conflict (clave) do nothing
    returning avisos_enviados.clave
  )
  select d.perfil_id,
         case when d.idioma = 'es' then d.t_es else d.t_en end,
         case when d.idioma = 'es' then d.c_es else d.c_en end,
         d.url, d.clave,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                   from public.suscripciones s where s.perfil_id = d.perfil_id), '[]'::jsonb)
  from _dest d join nuevos n on n.clave = d.clave;
end $$;

-- 7. Permisos -------------------------------------------------------------------------------------
revoke execute on function public.llegar_limpieza(uuid, text, double precision, double precision, double precision), public.soltar_sala(uuid, text),
  public.equipos_activos(), public.guardar_equipo(uuid[]), public.deshacer_equipo(uuid), public.salas_dia(date), public.tiempos_salas(int) from public, anon;
grant  execute on function public.llegar_limpieza(uuid, text, double precision, double precision, double precision), public.soltar_sala(uuid, text),
  public.equipos_activos(), public.guardar_equipo(uuid[]), public.deshacer_equipo(uuid), public.salas_dia(date), public.tiempos_salas(int) to authenticated;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;


-- ═══════════════ 32-PEGAR-horario.sql ═══════════════
-- OpsFlow · horario estimado de cada equipo: la hora de entrada solo vale para el PRIMER apartamento (13 oct 2026)
-- Corrección de Ivan a SPEC-rutas-driver. Ejecutar DESPUES de 30-PEGAR-equipos.sql. Se puede ejecutar varias veces.
--   · 1er apartamento del equipo: la hora de entrada (11:00 si nadie la cambió), nunca antes del check-out del huésped.
--   · Los siguientes: fin estimado del anterior + 15 min de traslado (y nunca antes de su check-out).
--   · Duración estimada: la mediana real de ese apartamento y tipo (si hay 3 o más limpiezas con QR en 90 días);
--     si no, la de la tabla duracion_tipo (Operación la puede cambiar).
--   · En cuanto un apartamento empieza o termina de verdad, los siguientes se recalculan con la hora real.
--   · La bolsa de linens de cada apartamento debe llegar antes de la hora (estimada) en que el equipo entra en él.

-- 1. Duración por defecto de cada tipo de limpieza (mientras no hay datos reales) ----------------
create table if not exists public.duracion_tipo (
  tipo    public.tipo_limpieza primary key,
  minutos int not null check (minutos between 10 and 600)
);
alter table public.duracion_tipo enable row level security;
revoke all on public.duracion_tipo from anon;
revoke insert, update, delete, truncate on public.duracion_tipo from authenticated;
drop policy if exists "duracion_tipo: lectura" on public.duracion_tipo;
create policy "duracion_tipo: lectura" on public.duracion_tipo for select to authenticated using (true);
insert into public.duracion_tipo (tipo, minutos) values
  ('normal', 90), ('refresh', 45), ('deep', 180), ('huesped_dentro', 45), ('foto', 60), ('post_mantenimiento', 60)
on conflict (tipo) do nothing;

-- Minutos estimados de una limpieza: la mediana real del apartamento (3+ medidas) o el valor por defecto del tipo
create or replace function public._duracion(p_prop uuid, p_tipo public.tipo_limpieza)
returns int language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select round(percentile_cont(0.5) within group (order by extract(epoch from (l.fin - l.inicio)) / 60))::int
       from public.limpiezas l
      where l.propiedad_id = p_prop and l.tipo = p_tipo and l.estado = 'terminada' and l.inicio_qr and l.fin_qr
        and l.fecha >= (now() at time zone 'Europe/Malta')::date - 90
        and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'
      having count(*) >= 3),
    (select minutos from public.duracion_tipo where tipo = p_tipo), 90)
$$;

-- 2. Horario del día de un equipo (por su responsable) ---------------------------------------------
create or replace function public._horario_equipo(p_fecha date, p_cleaner uuid)
returns table (limpieza_id uuid, inicio timestamptz, fin timestamptz, primera boolean, real_inicio boolean, minutos int)
language plpgsql stable security definer set search_path = ''
as $$
declare r record; t timestamptz; fin_prev timestamptz := null; n int := 0; d int;
begin
  for r in select l.id, l.inicio, l.fin, l.estado, l.tipo, l.propiedad_id, c.hora_salida
             from public.limpiezas l join public.checkouts c on c.id = l.checkout_id
            where l.fecha = p_fecha and l.asignada_a = p_cleaner and l.estado::text <> 'cancelada'
            order by l.orden nulls last, l.creado_en
  loop
    n := n + 1;
    t := case when n = 1 then (p_fecha + public._hora_entrada(p_fecha, p_cleaner)) at time zone 'Europe/Malta'
              else fin_prev + interval '15 minutes' end;
    if r.hora_salida is not null then t := greatest(t, (p_fecha + r.hora_salida) at time zone 'Europe/Malta'); end if;
    d := public._duracion(r.propiedad_id, r.tipo);
    limpieza_id := r.id; primera := n = 1; minutos := d;
    real_inicio := r.inicio is not null;
    inicio := coalesce(r.inicio, t);
    fin := coalesce(r.fin, greatest(inicio + make_interval(mins => d), case when r.estado = 'en_curso' then now() end));
    fin_prev := fin;
    return next;
  end loop;
end $$;
revoke execute on function public._duracion(uuid, public.tipo_limpieza), public._horario_equipo(date, uuid) from public, anon, authenticated;

-- La hora límite de la bolsa = la hora (estimada) en que el equipo entra en ESE apartamento
create or replace function public._limite_bolsa(p_limpieza uuid)
returns timestamptz language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select h.inicio from public.limpiezas l, public._horario_equipo(l.fecha, l.asignada_a) h
      where l.id = p_limpieza and l.asignada_a is not null and h.limpieza_id = l.id),
    (select (l.fecha + time '11:00') at time zone 'Europe/Malta' from public.limpiezas l where l.id = p_limpieza))
$$;
-- ¿Es la hora fija del primer apartamento (true) o una estimación (false)?
create or replace function public._limite_fijo(p_limpieza uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select coalesce((select h.primera and not h.real_inicio from public.limpiezas l, public._horario_equipo(l.fecha, l.asignada_a) h
                    where l.id = p_limpieza and h.limpieza_id = l.id), true)
$$;
revoke execute on function public._limite_bolsa(uuid), public._limite_fijo(uuid) from public, anon, authenticated;

-- 3. Horario del día para los líderes (Asignar, Seguimiento, Drivers) -------------------------------
create or replace function public.horario_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public._lider_limpieza() or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo los líderes u Operación.';
  end if;
  return coalesce((select jsonb_object_agg(h.limpieza_id, jsonb_build_object(
      'inicio', to_char(h.inicio at time zone 'Europe/Malta', 'HH24:MI'), 'fin', to_char(h.fin at time zone 'Europe/Malta', 'HH24:MI'),
      'primera', h.primera, 'real', h.real_inicio, 'minutos', h.minutos))
    from (select distinct asignada_a from public.limpiezas where fecha = p_fecha and asignada_a is not null) e,
         public._horario_equipo(p_fecha, e.asignada_a) h), '{}'::jsonb);
end $$;
revoke execute on function public.horario_dia(date) from public, anon;
grant  execute on function public.horario_dia(date) to authenticated;

-- 4. Pantallas ---------------------------------------------------------------------------------------
-- Día del cleaner: + a qué hora empieza cada apartamento (la del 1º es la de entrada; las demás, estimadas)
create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden,
      'con', (select string_agg(split_part(pf.nombre, ' ', 1), ', ' order by pf.nombre) from public.perfiles pf
              where pf.id = any(public._miembros_de(l.id)) and pf.id <> (select auth.uid())),
      'presente', public._presente(l.id),
      'inicio', to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI'), 'inicio_fijo', public._limite_fijo(l.id), 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar, 'linens_revisado', l.linens_revisado,
      'bolsa', (select jsonb_build_object('estado', b.estado, 'entregada_en', to_char(b.entregada_en at time zone 'Europe/Malta', 'HH24:MI'), 'comentario', b.comentario) from public.bolsas b where b.limpieza_id = l.id),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado, 'items', pe.items,
                     'listo_a', to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI'), 'listo_creado', case when pe.listo_a is not null then pe.creado_en end) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and public._soy_miembro(l.id) and l.estado::text <> 'cancelada'
      and public.mi_nivel() is not null
  ) t
$$;

-- Driver: + si la hora límite de la bolsa es la de entrada (fija) o estimada
create or replace function public.mis_trabajos()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return jsonb_build_object(
    'bolsas', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'limpieza_id', b.limpieza_id, 'zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'incidencia', b.incidencia,
        'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end,
        'limite', to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI'), 'limite_fijo', public._limite_fijo(l.id),
        'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end, 'coord', p.coord_estado)
        order by public._limite_bolsa(l.id), (c.fecha = v_hoy and c.hora_entrada is not null) desc, c.hora_entrada, p.codigo)
      from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
      join public.checkouts c on c.id = l.checkout_id
      where b.driver = (select auth.uid()) and b.estado = 'en_camion'), '[]'::jsonb),
    'listas', coalesce((select jsonb_agg(jsonb_build_object('zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'limite', to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI'))
        order by public._limite_bolsa(l.id), c.hora_entrada nulls last, p.codigo)
      from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
      join public.checkouts c on c.id = l.checkout_id
      where b.fecha = v_hoy and b.estado = 'preparada' and l.estado::text <> 'cancelada'), '[]'::jsonb));
end $$;

commit;

-- Si llegaste aquí sin errores: el proyecto de pruebas tiene el backend 1–33.
