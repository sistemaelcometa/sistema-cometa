# El Cometa agricola

Aplicar una vez en Supabase la migracion `074_cometa_agricultural_movements.sql`.
El modulo tiene sus propias tablas, permisos y auditoria. No agrega movimientos a los reportes de Alquileres.

Ingresos: Ventas de cereal, Ventas de bienes de uso.
Egresos: Combustible (ciudad), Insumos (incluye combustible para labores de campo),
Gastos de comercializacion, Reparaciones, Gastos varios, Alquileres y Seguros.
Los importes admiten centavos. Pesos argentinos y dolares se muestran por separado sin conversion.
Los filtros se aplican tanto a la tabla como a los totales y al grafico; la paginacion afecta solo a las filas.
Los movimientos anulados conservan el comprobante y la auditoria.

## Bolsas archivadas automaticamente

Aplicar `085_cometa_archive_empty_bags.sql` despues de `084_cometa_bag_numbers.sql`.
Una bolsa con entradas validas y saldo cero queda archivada automaticamente. Desaparece
de los destinos disponibles de cosechas y traslados, y de las tarjetas activas de Acopio.
Se conserva en **Silos bolsa archivados** y en el historial, con su numero permanente.
Las bolsas nuevas sin entradas y los silos fijos vacios siguen disponibles.

Supabase tambien rechaza nuevas cargas a bolsas archivadas, incluso desde pestañas antiguas.
El estado se calcula con los movimientos validos, por lo que anular una salida que restaura
existencias vuelve a activar la bolsa. Anular una primera carga erronea la deja sin uso.
No se borran movimientos, cosechas ni archivos y no se registra dinero en Caja.

## Identidad de silos bolsa

Aplicar `084_cometa_bag_numbers.sql` para numerar las bolsas existentes y nuevas.
Cada bolsa tiene un numero interno permanente por organizacion (SB-0001, SB-0002, etc.).
Puede repetirse su nombre y ubicacion: cada nueva bolsa conserva su propio UUID, stock,
carga de referencia e historial. El numero aparece en tarjetas, selectores e historial.
Editar nombre o ubicacion no cambia ese numero; el tipo de almacenamiento es permanente.
La numeracion no se reinicia al vaciar una bolsa. Los silos fijos conservan la restriccion
de nombre unico por ubicacion. Crear desde Cosecha devuelve el numero inmediatamente y
los reintentos de guardado conservan la identidad para evitar crear otra bolsa por error.

## Traslados y liquidacion de stock

Aplicar `083_cometa_clear_stock.sql` despues de `081_cometa_multi_source_extractions.sql`.
En Acopio, **Trasladar mercaderia** permite mover una o varias partidas entre silos fijos
y silos bolsa. **Usar todo el stock del silo** completa todas sus partidas; el traslado
conserva lote, cultivo, campana y toneladas totales, y deja el origen en cero si se mueve todo.

**Liquidar stock** da de baja todo el remanente de un almacenamiento, con fecha y motivo.
La operacion comprueba el saldo mostrado bajo el mismo bloqueo que los otros movimientos
de grano, para evitar liquidar silenciosamente un stock que cambio en otra sesion.
El historial la identifica como Liquidacion de stock y agrupa sus partidas. Se puede anular
completa si no tiene operaciones posteriores. Los reintentos conservan su identidad y no
duplican la baja. No borra cosechas, silos ni historial, y no genera dinero en Caja.

## Proveedores y compradores

Aplicar `082_cometa_contacts.sql` despues de `077_cometa_suppliers.sql`.
La seccion **Contactos** unifica proveedores y compradores. Cada persona o empresa tiene
un solo registro con tipo Proveedor, Comprador o Proveedor y comprador. Los proveedores
existentes conservan su identificador y quedan como Proveedor; se puede editar su tipo.
La unicidad del nombre se mantiene entre todos los tipos dentro de cada organizacion.

En Caja, los egresos sugieren proveedores y los ingresos compradores; los de ambos tipos
aparecen en las dos listas. Las ventas directas desde cosecha y las extracciones de grano
tambien ofrecen los contactos como destinos, incluyendo entregas a proveedores.
Siempre se puede escribir un nombre o detalle manualmente. Archivar o editar un contacto
no modifica el nombre historico de los movimientos ni genera movimientos de dinero.

## Comprobantes y descarga mensual

Aplicar tambien `075_cometa_receipt_archives.sql`.
Cada movimiento recibe un numero interno consecutivo por organizacion y mes, por ejemplo
`202610-0001`. Este numero se conserva aunque se anule el movimiento o se archive su archivo.
El numero fiscal de la factura se guarda aparte.

Las fotos se convierten siempre a WebP (hasta 2000 px de lado mayor, calidad 80).
Un error de conversion impide subir el original silenciosamente. Los PDF conservan su formato.
El comprobante es opcional al crear el movimiento y se puede adjuntar despues.

El boton **Descargar facturas del mes** abre un selector de mes y anio independiente de los filtros.
Se puede descargar octubre durante noviembre. El ZIP contiene una carpeta `Octubre 2026`,
los archivos numerados, `indice.csv` con TODOS los movimientos del mes y
`manifest.json` con hashes SHA-256 de los archivos incluidos. Tambien incluye comprobantes de movimientos anulados.
Cada ZIP tiene un nombre unico para evitar pisar descargas anteriores del mismo mes.
En computadoras compatibles se escribe directamente al disco; el resto de navegadores usa
una descarga en memoria limitada a 250 MB para evitar agotarla.

Generar el ZIP no borra archivos. Despues de guardarlo y verificarlo, el usuario marca la confirmacion
y elige **Eliminar comprobantes online de esta descarga**.
La politica de Storage permite borrar solo los archivos de esa exportacion completada y confirmada.
La comprobacion posterior marca como archivados solo los archivos que ya no existen en Storage.
Si una limpieza falla a medias, se puede reintentar. Los comprobantes cargados despues de la
exportacion y los restaurados con una carga nueva quedan protegidos.
Los movimientos, numeros, importes y auditoria permanecen. Un comprobante archivado ya no se descarga
desde el sistema; se consulta en el ZIP local y puede volver a adjuntarse.

## Lectura opcional de facturas

Por decision del usuario, la lectura automatica queda postergada y desactivada por defecto.
El formulario muestra la carga manual y permite adjuntar una foto o PDF.
Tener una clave configurada no activa la funcion por si solo.

En el servidor de produccion (por ejemplo, variables de entorno de Vercel), configurar:

- `OPENAI_API_KEY`: clave privada de la API de OpenAI. Nunca usar un prefijo `NEXT_PUBLIC_`.
- `OPENAI_INVOICE_MODEL`: opcional; por defecto `gpt-4.1-mini`.
- `COMETA_INVOICE_AI_ENABLED=true`: solo cuando se decida retomar la funcion. Por defecto esta desactivada.

Volver a desplegar despues de configurar las variables. La API requiere una cuenta con
acceso y facturacion habilitados. La suscripcion de ChatGPT no configura esta integracion.
La clave nunca se ingresa en el formulario ni se envia al navegador.

El usuario elige Sacar foto o Cargar PDF o imagen y luego Leer factura.
La lectura solo genera un borrador. El usuario puede corregir cualquier campo y debe
marcar la confirmacion de revision antes de guardar. La IA no registra dinero.
Sin clave, o si falla la lectura, se puede adjuntar el comprobante y completar los datos manualmente.

Archivos admitidos: PDF, JPG, PNG y WebP, hasta 20 MB para adjuntar y hasta 3 MB para lectura automatica.
Las imagenes se optimizan en el navegador usando la misma compresion del resto de la app.
Los comprobantes se guardan en el bucket privado existente `receipts`, bajo la organizacion y
la operacion del movimiento. La lectura usa URLs firmadas de corta duracion.

Implementacion basada en la documentacion oficial:
[archivos](https://developers.openai.com/api/docs/guides/file-inputs),
[salidas estructuradas](https://developers.openai.com/api/docs/guides/structured-outputs).
