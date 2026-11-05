const supported=["application/pdf","image/jpeg","image/png","image/webp"];
export async function prepareCometaReceipt(file:File):Promise<File>{
 if(!supported.includes(file.type)||!file.size||file.size>20*1024*1024)throw new Error("Usá PDF, JPG, PNG o WebP de hasta 20 MB.");
 if(file.type==="application/pdf")return file;
 let source:ImageBitmap|HTMLImageElement;
 if("createImageBitmap" in globalThis)source=await createImageBitmap(file);
 else{
  const url=URL.createObjectURL(file);
  try{source=await new Promise<HTMLImageElement>((resolve,reject)=>{const image=new Image();image.onload=()=>resolve(image);image.onerror=()=>reject(new Error("No se pudo leer la imagen."));image.src=url})}
  finally{URL.revokeObjectURL(url)}
 }
 try{
  if(!source.width||!source.height)throw new Error("La imagen no tiene un tamaño válido.");
  const scale=Math.min(1,2000/Math.max(source.width,source.height)),canvas=document.createElement("canvas");
  canvas.width=Math.max(1,Math.round(source.width*scale));canvas.height=Math.max(1,Math.round(source.height*scale));
  const context=canvas.getContext("2d");if(!context)throw new Error("El navegador no puede convertir esta imagen.");
  context.drawImage(source,0,0,canvas.width,canvas.height);
  const blob=await new Promise<Blob|null>(resolve=>canvas.toBlob(resolve,"image/webp",0.8));
  if(!blob||blob.type!=="image/webp")throw new Error("No se pudo convertir a WebP. Probá con otro navegador o cargá un PDF.");
  return new File([blob],file.name.replace(/\.[^.]+$/,"")+".webp",{type:"image/webp",lastModified:file.lastModified});
 }finally{if("close" in source)source.close()}
}

export function receiptNumber(row:{receipt_month?:string;receipt_number?:number}){
 return row.receipt_number?String(row.receipt_month||"").slice(0,7).replace("-","")+"-"+String(row.receipt_number).padStart(4,"0"):"Sin número";
}
export function receiptFilename(row:{receipt_number?:number;receipt_name?:string|null;path?:string|null;receipt_path?:string|null}){
 const path=row.path||row.receipt_path||row.receipt_name||"",extension=path.split(".").pop()?.toLowerCase();
 return String(row.receipt_number||0).padStart(4,"0")+"."+(/^(pdf|webp|jpg|jpeg|png)$/.test(extension||"")?extension:"bin");
}
export function receiptMonthName(month:string){
 if(!/^\d{4}-(0[1-9]|1[0-2])$/.test(month))throw new Error("Elegí un mes válido.");
 const names=["Enero","Febrero","Marzo","Abril","Mayo","Junio","Julio","Agosto","Septiembre","Octubre","Noviembre","Diciembre"];
 return names[Number(month.slice(5,7))-1]+" "+month.slice(0,4);
}
export type ReceiptSnapshot={
 movement_id:string;path:string|null;receipt_name:string|null;receipt_number:number;receipt_month:string;
 movement_date:string;kind:string;category:string;concept:string;counterparty:string|null;document_number:string|null;
 amount:number;currency:string;status:string;receipt_archived_at:string|null;
};
export type ReceiptManifest={movement_id:string;path:string;sha256:string;bytes:number};
function csvCell(value:unknown){
 let text=String(value??"");
 if(/^[\s]*[=+@-]/.test(text))text="'"+text;
 return '"'+text.replaceAll('"','""')+'"';
}
export function receiptIndex(rows:ReceiptSnapshot[]){
 const table:unknown[][]=[["Comprobante interno","Fecha","Tipo","Categoría","Concepto","Contraparte","Número fiscal de factura","Moneda","Importe","Estado","Archivo"]];
 for(const row of rows)table.push([receiptNumber(row),row.movement_date,row.kind==="income"?"Ingreso":"Egreso",row.category,row.concept,row.counterparty,row.document_number,row.currency,Number(row.amount).toFixed(2),row.status==="valid"?"Vigente":"Anulado",row.path&&!row.receipt_archived_at?receiptFilename(row):row.receipt_archived_at?"Archivado anteriormente":"Sin adjuntar"]);
 return "\uFEFF"+table.map(line=>line.map(csvCell).join(";")).join("\r\n");
}

const crcTable=Array.from({length:256},(_,n)=>{let c=n;for(let k=0;k<8;k++)c=c&1?0xedb88320^(c>>>1):c>>>1;return c>>>0});
export function crc32(data:Uint8Array){let crc=0xffffffff;for(const byte of data)crc=crcTable[(crc^byte)&255]^(crc>>>8);return(crc^0xffffffff)>>>0}
export type ZipEntry={name:string;data:Uint8Array};
// Stored ZIP entries: WebP/PDF are already compressed. Only the central directory
// is retained while streaming; file data can be released after each entry.
export async function* receiptZip(entries:AsyncIterable<ZipEntry>):AsyncGenerator<Uint8Array>{
 const directory:Uint8Array[]=[];let offset=0,count=0;
 const utf8=new TextEncoder();
 const now=new Date(),stamp=((Math.max(1980,Math.min(2107,now.getFullYear()))-1980)<<9)|((now.getMonth()+1)<<5)|now.getDate();
 const time=(now.getHours()<<11)|(now.getMinutes()<<5)|Math.floor(now.getSeconds()/2);
 for await(const entry of entries){
  if(entry.name.startsWith("/")||entry.name.split("/").includes("..")||entry.name.includes("\\"))throw new Error("Nombre de archivo inválido.");
  const name=utf8.encode(entry.name),size=entry.data.byteLength,checksum=crc32(entry.data);
  if(name.length>65535||count>=65534||offset+size+name.length+30>=0xffffffff)throw new Error("El archivo es demasiado grande para este ZIP.");
  const header=new Uint8Array(30+name.length),view=new DataView(header.buffer);
  view.setUint32(0,0x04034b50,true);view.setUint16(4,20,true);view.setUint16(6,0x0800,true);
  view.setUint16(10,time,true);view.setUint16(12,stamp,true);view.setUint32(14,checksum,true);view.setUint32(18,size,true);view.setUint32(22,size,true);view.setUint16(26,name.length,true);header.set(name,30);
  const central=new Uint8Array(46+name.length),cv=new DataView(central.buffer);
  cv.setUint32(0,0x02014b50,true);cv.setUint16(4,20,true);cv.setUint16(6,20,true);cv.setUint16(8,0x0800,true);cv.setUint16(12,time,true);cv.setUint16(14,stamp,true);
  cv.setUint32(16,checksum,true);cv.setUint32(20,size,true);cv.setUint32(24,size,true);cv.setUint16(28,name.length,true);cv.setUint32(42,offset,true);central.set(name,46);
  directory.push(central);count++;offset+=header.length+size;yield header;yield entry.data;
 }
 let directorySize=0;for(const central of directory){directorySize+=central.length;yield central}
 const end=new Uint8Array(22),view=new DataView(end.buffer);
 view.setUint32(0,0x06054b50,true);view.setUint16(8,count,true);view.setUint16(10,count,true);view.setUint32(12,directorySize,true);view.setUint32(16,offset,true);yield end;
}
