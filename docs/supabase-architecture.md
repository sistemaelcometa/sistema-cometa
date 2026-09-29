# Arquitectura Supabase - El Cometa

Este documento define el contrato inicial de datos para migrar el sistema a Supabase/PostgreSQL sin convertir el frontend en fuente de verdad.

## Principios

- Supabase/PostgreSQL es la unica fuente de verdad.
- El frontend envia intenciones y datos de entrada, no estados finales criticos.
- Los saldos, estados derivados, totales, margenes y reportes se calculan desde datos confirmados.
- Las escrituras criticas deben pasar por RPCs transaccionales.
- Las lecturas deben filtrar, ordenar y paginar en PostgreSQL.
- El cache futuro es descartable y nunca reemplaza a la base.
- Realtime se usara para invalidar/refrescar consultas puntuales, no para reconstruir toda la app.

## Decisiones Cerradas

- Habra un usuario admin principal.
- Los usuarios se registran con email y quedan sin permisos hasta que el admin los habilite.
- El uso normal sera de un usuario, pero el modelo queda preparado para varios usuarios concurrentes.
- Punta del Este es una seccion separada de Alquileres Urbanos.
- Los departamentos PDE `209` y `601` no pertenecen al modelo de edificios urbanos.
- No se borran datos criticos fisicamente como regla general: se archivan, cancelan o anulan.
- Los comprobantes, contratos y documentos se guardan como archivos reales en Supabase Storage.
- La liquidacion familiar se cierra congelada, con snapshot, y puede corregirse/editase luego con auditoria.

## Modulos

1. Autenticacion y permisos
2. Alquileres Urbanos
3. Expensas
4. Cobros urbanos
5. Liquidaciones familiares
6. Mantenimiento
7. Punta del Este
8. Calendarios y notas
9. Archivos/comprobantes
10. Auditoria

## Roles

- `owner`: control total, administra usuarios y configuracion.
- `admin`: administra datos de negocio y usuarios operativos.
- `editor`: carga y modifica operaciones normales.
- `viewer`: solo lectura.

Regla: la interfaz puede ocultar botones, pero la seguridad real vive en RLS y RPCs.

## Entidades Y Tablas Propuestas

### Base Organizacional

`organizations`
- Empresa/organizacion del sistema.
- Fuente de verdad del scope multiusuario.

`profiles`
- Perfil conectado a `auth.users`.
- Guarda nombre visible, email y estado.

`organization_members`
- Relacion usuario-organizacion.
- Campos: `organization_id`, `user_id`, `role`, `status`.
- Estados sugeridos: `pending`, `active`, `disabled`.
- Solo `owner/admin` puede activar y asignar rol.

### Contactos

`contacts`
- Personas y empresas: inquilinos, huespedes, proveedores, profesionales, beneficiarios familiares.
- Campos de busqueda: nombre, apellido, razon social, telefono, email, documento.
- Flags: `is_tenant`, `is_guest`, `is_provider`, `is_worker`, `is_family_beneficiary`.
- No duplicar un contacto si puede cumplir mas de un rol.

### Alquileres Urbanos

`urban_buildings`
- Edificios urbanos.
- Campos: nombre, direccion, `has_expenses`, estado.
- Estados: `active`, `archived`.

`urban_units`
- Departamentos urbanos.
- Pertenece a `urban_buildings`.
- Campos: nombre, superficie, estado, observaciones.
- Estados: `available`, `rented`, `maintenance`, `archived`.
- La superficie se usa para calcular expensas.

`urban_leases`
- Contratos/alquileres fijos.
- Pertenece a una unidad.
- Relaciona inquilino principal via `contact_id`.
- Campos: fechas, monto actual, moneda, dia de vencimiento, frecuencia de ajuste, proximo ajuste.
- Estados: `upcoming`, `active`, `finalized`, `rescinded`, `archived`.
- Debe impedir contratos activos solapados para la misma unidad.

`urban_lease_adjustments`
- Historial de cambios de monto.
- Guarda monto anterior, monto nuevo, fecha efectiva, usuario y notas.

### Cargos Y Cobros Urbanos

`urban_charges`
- Cargos por periodo para una unidad/contrato.
- No es solo alquiler: es el encabezado del vencimiento.
- Estados: `pending`, `partial`, `paid`, `cancelled`.
- Unique sugerido: contrato + periodo.

`urban_charge_items`
- Detalle del cargo.
- Tipos: `rent`, `rent_surcharge`, `building_expense`, `expense_surcharge`, `unit_expense`, `rescission`, `other`.
- El total del cargo es derivado de sus items.

`urban_payments`
- Cobros reales.
- Campos: fecha, importe, moneda, metodo, estado, observaciones.
- Estados: `valid`, `voided`.
- No debe guardar saldo final como autoridad.

`urban_payment_allocations`
- Imputacion de un cobro a items de cargo.
- Permite saber cuanto fue a alquiler, recargo de alquiler, expensas, recargo de expensas, etc.
- La suma imputada no puede superar el importe cobrado ni el saldo del item.

### Expensas

`expense_categories`
- Rubros configurables.
- Para PDE inicialmente: Expensas, Limpieza, UTE, Primarias, Contribucion Inmobiliaria, Administracion, Mantenimiento, Otros.
- Para urbanos puede ampliarse por edificio.

`urban_expense_periods`
- Periodo de expensas por edificio.
- Estados: `draft`, `calculated`, `closed`, `cancelled`.

`urban_expense_items`
- Gastos cargados en un periodo.
- Campos: categoria, detalle, fecha, importe, comprobante opcional, criterio de traslado.
- Estados: `valid`, `voided`.

`urban_expense_allocations`
- Resultado de distribuir gastos por superficie.
- Snapshot de superficie de la unidad y total del edificio al momento de calcular.
- Puede generar items en `urban_charge_items`.

### Liquidacion Familiar

`family_distribution_groups`
- Configuracion de distribucion por unidad y vigencia.
- Evita pisar historicos.

`family_distribution_shares`
- Beneficiario + porcentaje.
- La suma por grupo activo debe ser 100%.

`family_settlements`
- Liquidacion cerrada por periodo.
- Estados: `draft`, `closed`, `corrected`, `cancelled`.
- Guarda totales congelados ARS/USD.

`family_settlement_items`
- Snapshot de cada pago incluido, unidad, beneficiario, porcentaje e importe.
- No depende de recalcular a futuro con porcentajes nuevos.

`family_settlement_corrections`
- Correcciones posteriores a una liquidacion cerrada.
- Guarda motivo, usuario y cambios relevantes.

### Mantenimiento

`maintenance_tasks`
- Tareas por departamento urbano.
- Estados: `open`, `finished`, `cancelled`.
- Campos: titulo, detalle, profesional, fechas.

`maintenance_expenses`
- Gastos dentro de una tarea.
- Campos: concepto, fecha, importe, comprobante, estado.
- Estados: `valid`, `voided`.

### Punta Del Este

`pde_units`
- Unidades temporarias independientes.
- Inicialmente `209` y `601`.
- Campos: nombre, descripcion opcional, estado.
- Estados: `active`, `archived`.

`pde_reservations`
- Reservas temporarias.
- Pertenece a `pde_units`.
- Campos: huesped, fecha ingreso, fecha egreso, noches, total, moneda, estado.
- Estados: `reserved`, `deposit_received`, `paid`, `cancelled`, `finished`.
- Noches y valor por noche son derivados desde fechas y total.
- Debe impedir solapamiento de reservas activas en la misma unidad.

`pde_reservation_payments`
- Cobros de reservas.
- Tipos: `deposit`, `balance`, `other`.
- Estados: `valid`, `voided`.
- El estado de la reserva se determina desde pagos confirmados.

`pde_expenses`
- Gastos PDE.
- Puede aplicar a `209`, `601` o `general_50_50`.
- Campos: rubro, detalle, fecha, importe, comprobante, estado.
- Si es general, PostgreSQL debe dividir 50/50 mediante registros derivados o allocations.

`pde_expense_allocations`
- Resultado de asignar gasto PDE a una unidad.
- Para gasto general guarda dos filas, una por cada unidad.

### Calendarios

`calendar_notes`
- Notas manuales.
- Scope: `urban`, `pde`, `general`.
- No reemplaza vencimientos ni reservas, solo eventos manuales.

### Archivos

`files`
- Metadata del archivo en Storage.
- Campos: bucket, path, nombre original, mime, size, usuario, estado.
- Estados: `active`, `archived`.

`file_links`
- Relaciona archivo con entidad.
- Entidades: contrato, cobro urbano, gasto expensas, mantenimiento, reserva PDE, cobro PDE, gasto PDE, liquidacion.

### Auditoria

`audit_logs`
- Guarda operaciones importantes.
- Campos: usuario, accion, entidad, entidad_id, valores antes/despues relevantes, fecha, request_id.
- No se audita todo automaticamente si no aporta valor, pero si toda operacion critica.

## Fuente De Verdad

- Saldo urbano: `urban_charge_items` menos `urban_payment_allocations`.
- Estado de cargo: derivado de items e imputaciones, o actualizado por RPC luego de validar.
- Total de cobro: `urban_payments.received_amount`.
- Total de cargo: suma de `urban_charge_items`.
- Expensas liquidadas: `urban_expense_allocations` y items generados.
- Liquidacion familiar cerrada: `family_settlement_items` congelados.
- Saldo PDE: pagos validos de reservas menos gastos PDE asignados.
- Estado reserva PDE: pagos validos contra total, cancelacion y fecha de salida.
- Valor por noche PDE: total / noches.
- Reportes: consultas/agregados desde movimientos confirmados.

## Escrituras Seguras Como Insert/Update Directo

Solo si RLS lo permite y no afectan saldos ni estados derivados criticos:

- Crear nota de calendario.
- Editar nota de calendario.
- Archivar nota.
- Crear contacto simple.
- Editar datos basicos de contacto.
- Crear categoria/rubro.
- Editar descripcion de archivo.

Incluso estas escrituras deben guardar `organization_id`, `created_by`, timestamps y respetar RLS.

## Operaciones Que Deben Ser RPC

Prioridad alta:

- `invite_or_enable_member`
- `create_urban_building`
- `archive_urban_building`
- `create_urban_unit`
- `archive_urban_unit`
- `create_urban_lease`
- `finalize_urban_lease`
- `adjust_urban_rent`
- `generate_urban_charge`
- `register_urban_payment`
- `void_urban_payment`
- `create_urban_expense_period`
- `add_urban_expense_item`
- `void_urban_expense_item`
- `calculate_urban_expense_allocations`
- `close_family_settlement`
- `correct_family_settlement`
- `create_pde_reservation`
- `update_pde_reservation`
- `cancel_pde_reservation`
- `register_pde_payment`
- `void_pde_payment`
- `register_pde_expense`
- `void_pde_expense`
- `create_file_link`

Prioridad media:

- `create_maintenance_task`
- `finish_maintenance_task`
- `add_maintenance_expense`
- `void_maintenance_expense`
- `update_distribution_group`

## Reglas Para RPCs Criticas

Cada RPC critica debe:

1. Validar `auth.uid()`.
2. Validar membresia activa en la organizacion.
3. Validar rol/permisos.
4. Validar datos de entrada.
5. Bloquear filas relevantes si hay riesgo de concurrencia.
6. Ejecutar todos los cambios en una transaccion.
7. Registrar auditoria.
8. Devolver el resultado confirmado.
9. Hacer rollback completo si algo falla.

## Concurrencia

Operaciones con control fuerte:

- Crear reserva PDE: impedir solapamientos por unidad.
- Actualizar reserva PDE: revalidar solapamientos.
- Registrar cobro urbano: evitar sobreimputar cargo.
- Registrar cobro PDE: evitar pagos duplicados/superiores al saldo.
- Calcular expensas: evitar recalcular/cerrar dos veces el mismo periodo.
- Cerrar liquidacion familiar: evitar dos cierres del mismo periodo.
- Crear contrato urbano: impedir contratos activos solapados.
- Archivar unidad/edificio: validar dependencias activas.

Herramientas:

- constraints y unique indexes.
- exclusion constraints para rangos de fechas.
- `select ... for update` dentro de RPCs.
- estados `closed/cancelled/voided`.
- `operation_id` en operaciones con riesgo de retry.

## Idempotencia

Agregar `operation_id` en:

- cobros urbanos.
- anulacion de cobros urbanos.
- calculo/cierre de expensas.
- cierre/correccion de liquidacion familiar.
- creacion de reserva PDE.
- cobros PDE.
- gastos PDE.
- carga de archivos vinculada a operacion critica.

Unique sugerido: `organization_id + operation_id`.

## Lecturas Desde Supabase

No descargar tablas completas para filtrar en JavaScript.

Consultas/RPCs sugeridas:

- `get_urban_overview()`
- `get_urban_buildings_with_units()`
- `get_urban_pending_charges_page(filters, page, page_size)`
- `get_urban_payments_page(filters, page, page_size)`
- `get_unit_account_statement(unit_id, filters)`
- `get_expense_period_detail(building_id, period)`
- `get_family_settlements_page(filters, page, page_size)`
- `get_family_settlement_detail(settlement_id)`
- `get_maintenance_history_page(unit_id, filters, page, page_size)`
- `get_pde_calendar(month, year)`
- `get_pde_pending_reservations(filters, page, page_size)`
- `get_pde_reservation_history(filters, page, page_size)`
- `get_pde_movements_page(filters, page, page_size)`
- `get_urban_report_summary(period_filter)`
- `get_pde_report_summary(period_filter)`
- `get_calendar_events(scope, month, year)`

Filtros frecuentes:

- fecha desde/hasta.
- mes/anio.
- edificio.
- departamento.
- inquilino/huesped.
- tipo de movimiento.
- estado.
- rubro.
- metodo de pago.

## Indices Principales

- `organization_members(user_id, organization_id)`.
- `urban_buildings(organization_id, status)`.
- `urban_units(organization_id, building_id, status)`.
- `urban_leases(unit_id, status, start_date, end_date)`.
- `urban_charges(organization_id, unit_id, period_month, status)`.
- `urban_payments(organization_id, payment_date, status)`.
- `urban_expense_periods(building_id, period_month)`.
- `family_settlements(organization_id, period_start, period_end, status)`.
- `pde_reservations(unit_id, start_date, end_date, status)`.
- `pde_reservation_payments(reservation_id, payment_date, status)`.
- `pde_expenses(organization_id, expense_date, unit_id, status)`.
- `files(organization_id, bucket, storage_path)`.
- `audit_logs(organization_id, occurred_at desc)`.

Agregar indices de busqueda solo sobre campos realmente usados.

## RLS

Regla base:

- Todas las tablas con `organization_id` tienen RLS por membresia activa.
- `viewer` puede leer.
- `editor` puede operar escrituras normales por RPC.
- `admin/owner` puede administrar usuarios, archivar entidades y corregir liquidaciones.
- Las operaciones criticas se exponen preferentemente por RPC y no por permisos amplios de tabla.

Funciones de seguridad:

- `is_org_member(organization_id)`
- `has_org_role(organization_id, roles[])`
- `current_user_profile()`

Si se usa `security definer`:

- fijar `search_path`.
- validar `auth.uid()`.
- validar organizacion y rol.
- no aceptar IDs arbitrarios sin verificar pertenencia.

## Storage

Buckets privados:

- `contracts`
- `receipts`
- `maintenance`
- `settlements`

Paths sugeridos:

- `org/{organization_id}/contracts/{lease_id}/{file_id}`
- `org/{organization_id}/receipts/urban-payments/{payment_id}/{file_id}`
- `org/{organization_id}/receipts/pde-payments/{payment_id}/{file_id}`
- `org/{organization_id}/receipts/pde-expenses/{expense_id}/{file_id}`
- `org/{organization_id}/maintenance/{task_id}/{file_id}`
- `org/{organization_id}/settlements/{settlement_id}/{file_id}`

Los archivos privados se acceden con signed URLs generadas por backend/Supabase segun permisos.

## Auditoria

Auditar:

- altas, cambios y archivos de contratos.
- ajustes de alquiler.
- cobros y anulaciones.
- calculo/cierre/cancelacion de expensas.
- cierre/correccion de liquidaciones familiares.
- reservas PDE, cambios y cancelaciones.
- cobros/gastos PDE y anulaciones.
- archivos vinculados.
- cambios de roles/usuarios.
- archivado de edificios/unidades.

No auditar cada lectura ni cada cambio visual.

## Cache Futuro

No implementar cache hasta tener lecturas estables.

Formato conceptual:

```text
query_key = recurso + filtros + pagina + usuario/organizacion
```

Ejemplos:

- `urban_payments:org:period:page:filters`
- `pde_reservations:month:unit`
- `urban_dashboard:period`

El cache se invalida por operacion confirmada o evento Realtime.

## Realtime Futuro

Usar solo para invalidacion selectiva.

Candidatos:

- `urban_payments`
- `urban_charges`
- `pde_reservations`
- `pde_reservation_payments`
- `pde_expenses`
- `calendar_notes`

Flujo:

```text
Supabase cambia
Realtime avisa
se marca query vieja
refetch selectivo
UI actualiza
```

No usar Realtime para descargar toda la base.

## No Aplica A Este Sistema

Quedan excluidos del alcance:

- stock.
- productos.
- compras.
- ventas comerciales.
- taller.
- cierres de caja.

Los equivalentes criticos aca son:

- cobros.
- gastos.
- reservas.
- expensas.
- liquidaciones.
- contratos.
- comprobantes.

## Proximo Paso

Antes de modificar `supabase/migrations`, revisar este contrato y cerrar:

1. Nombres definitivos de tablas: prefijo `urban_`/`pde_` vs nombres generales con columna `area`.
2. Si habra una sola organizacion fija o soporte multi-organizacion real.
3. Si las liquidaciones familiares se corrigen creando version nueva o editando snapshot con historial.
4. Si la carga de archivo se hace antes o despues de crear la operacion principal.
5. Que reportes deben estar disponibles en la primera version conectada a Supabase.
