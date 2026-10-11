# IA en OpsFlow · Clasificar reportes

Cuando un cleaner manda un reporte **Other** («What is the problem?»), la IA propone:

- **Departamento**: Limpieza, Linens, Drivers, Bodega, Mantenimiento, Property manager, Reservaciones u Operación.
- **Urgencia**: alta, media o baja, según si hay check-in hoy.
- **Resumen en español** en una línea, con el motivo.

El líder ve la sugerencia en **Asignar → Pendientes del día** y pulsa **Confirmar**, o cambia el departamento antes de confirmar.
**La IA nunca asigna trabajo.** Si la IA falla o no está activada, el reporte llega igual que antes.

## Qué se manda a la IA

Solo el texto del reporte, si hay check-in hoy y el mes. **No se mandan** el código de la propiedad, nombres ni datos del huésped.

## Instalación (una sola vez)

1. **Base de datos.** Supabase → SQL Editor → pegar `002_ia_clasificar.sql` → Run.
2. **Clave de la IA.** Supabase → Edge Functions → Secrets:
   - `ANTHROPIC_API_KEY` = tu clave de console.anthropic.com
   - Opcional: `IA_LIMITE_MES` = máximo de llamadas al mes (por defecto 1500)
   - Para usar OpenAI en lugar de Anthropic: `IA_PROVEEDOR` = `openai` y `OPENAI_API_KEY`
3. **Función.** `supabase functions deploy clasificar`, o en el panel: Edge Functions → Create function → nombre `clasificar` → pegar `supabase/functions/clasificar/index.ts`.
4. **App.** Subir el nuevo `index.html` al repo. GitHub Pages lo publica solo.

La clave **nunca** va en `index.html`: el repo es público.

## Gasto

En la consola del proveedor, poner también un **límite de gasto mensual**. Es la segunda barrera, además de `IA_LIMITE_MES`.

## ¿Funciona? Medirlo en el piloto

```sql
select * from public.ia_aciertos;   -- por semana: sugeridas, aceptadas, corregidas, % acierto
```

Regla para decidir al final del piloto (4 semanas): si el acierto es **≥ 80 %**, el paso siguiente es que la sugerencia aceptada cree la tarea en el departamento. Si es menor, revisar qué corrigen los líderes y ajustar las reglas de `INSTRUCCIONES` en la función.

## Antes de usarlo con datos reales

Los reportes reales pueden mencionar cosas del huésped. Mandarlos a un proveedor externo de IA necesita el visto bueno de la empresa (RGPD). Con datos TEST no hay problema.
