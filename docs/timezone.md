# Zona Horaria

La zona horaria operativa del sistema es:

```text
America/Argentina/Buenos_Aires
```

## Aplicacion

Configurar en Vercel:

```text
TZ=America/Argentina/Buenos_Aires
NEXT_PUBLIC_APP_TIME_ZONE=America/Argentina/Buenos_Aires
```

`TZ` afecta runtime Node cuando corresponda. `NEXT_PUBLIC_APP_TIME_ZONE` deja disponible la zona horaria para formateos de frontend.

## Supabase/PostgreSQL

La migracion `002_set_argentina_timezone.sql` configura la zona horaria por defecto de la base:

```sql
alter database postgres
  set timezone to 'America/Argentina/Buenos_Aires';
```

Los timestamps de negocio deben guardarse como `timestamptz` cuando representen un instante real. Las fechas puras de negocio, como ingreso/egreso de reserva o periodos de expensas, deben guardarse como `date`.

## Regla

La base sigue siendo la fuente de verdad. El frontend no debe calcular fechas criticas como autoridad; debe enviar la intencion o la fecha ingresada y PostgreSQL debe confirmar el resultado.
