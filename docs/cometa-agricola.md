# El Cometa agricola

Aplicar una vez en Supabase la migracion `074_cometa_agricultural_movements.sql`.
El modulo tiene sus propias tablas, permisos y auditoria. No agrega movimientos a los reportes de Alquileres.

Ingresos: Ventas de cereal, Ventas de bienes de uso.
Egresos: Combustible (ciudad), Insumos (incluye combustible para labores de campo),
Gastos de comercializacion, Reparaciones, Gastos varios, Alquileres y Seguros.
Los importes admiten centavos. Pesos argentinos y dolares se muestran por separado sin conversion.
Los filtros se aplican tanto a la tabla como a los totales y al grafico; la paginacion afecta solo a las filas.
Los movimientos anulados conservan el comprobante y la auditoria.

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
