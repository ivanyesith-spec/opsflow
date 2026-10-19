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
