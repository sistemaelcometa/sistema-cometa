import {createClient} from "@supabase/supabase-js";
import {invoiceRequest,validateInvoiceDraft} from "@/lib/cometa-invoice";

export const runtime="nodejs";
export const maxDuration=60;
const headers={"Cache-Control":"no-store"};
const reply=(body:unknown,status=200)=>Response.json(body,{status,headers});
const aiEnabled=()=>process.env.COMETA_INVOICE_AI_ENABLED==="true"&&!!process.env.OPENAI_API_KEY;
export async function GET(){return reply({enabled:aiEnabled()});}

export async function POST(request:Request){
  try{
    const token=request.headers.get("authorization")?.match(/^Bearer (.+)$/)?.[1];
    if(!token)return reply({error:"Iniciá sesion para leer una factura."},401);
    const url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    if(!url||!key)return reply({error:"La lectura de facturas no esta disponible."},503);
    const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false},global:{headers:{Authorization:`Bearer ${token}`}}});
    const {data:user,error:authError}=await client.auth.getUser(token);
    if(authError||!user.user)return reply({error:"La sesion vencio. Volvé a iniciar sesion."},401);
    const length=Number(request.headers.get("content-length")||0);
    if(length>4*1024*1024)return reply({error:"Para la lectura automática, el archivo debe pesar menos de 3 MB."},413);
    const form=await request.formData(),organization=String(form.get("organizationId")||""),kind=String(form.get("kind")||"");
    if(!/^[a-f0-9-]{36}$/i.test(organization)||!["income","expense"].includes(kind))return reply({error:"Datos de la consulta invalidos."},400);
    const {data:allowed,error:roleError}=await client.rpc("has_org_role",{target_organization_id:organization,allowed_roles:["owner","admin","editor"]});
    if(roleError||!allowed)return reply({error:"No tenes permisos para registrar movimientos."},403);
    if(!aiEnabled())return reply({error:"La lectura automática no está habilitada. Podés completar los datos manualmente."},503);
    const file=form.get("file");
    if(!(file instanceof File)||file.size===0||file.size>3*1024*1024)return reply({error:"Elegí un archivo de hasta 3 MB."},400);
    if(!["application/pdf","image/jpeg","image/png","image/webp"].includes(file.type))return reply({error:"Usá PDF, JPG, PNG o WebP."},400);
    const bytes=new Uint8Array(await file.slice(0,12).arrayBuffer());
    const pdf=bytes[0]===37&&bytes[1]===80&&bytes[2]===68&&bytes[3]===70;
    const jpg=bytes[0]===255&&bytes[1]===216&&bytes[2]===255;
    const png=bytes[0]===137&&bytes[1]===80&&bytes[2]===78&&bytes[3]===71;
    const webp=String.fromCharCode(...bytes.slice(0,4))==="RIFF"&&String.fromCharCode(...bytes.slice(8,12))==="WEBP";
    if(!(file.type==="application/pdf"?pdf:file.type==="image/jpeg"?jpg:file.type==="image/png"?png:webp))return reply({error:"El contenido del archivo no coincide con su formato."},400);
    const {data:categories,error:categoryError}=await client.from("cometa_categories").select("id,name,description").eq("organization_id",organization).eq("kind",kind);
    if(categoryError)throw new Error("No se pudieron consultar las categorias.");
    const response=await fetch("https://api.openai.com/v1/responses",{
      method:"POST",headers:{Authorization:`Bearer ${process.env.OPENAI_API_KEY}`,"Content-Type":"application/json"},
      body:JSON.stringify(await invoiceRequest(file,kind,categories??[],process.env.OPENAI_INVOICE_MODEL||"gpt-4.1-mini")),
      signal:AbortSignal.timeout(45000),
    });
    if(!response.ok)return reply({error:"No se pudo leer la factura. Intentá nuevamente o completá los datos manualmente."},502);
    const result=await response.json();
    if(result.status!=="completed")return reply({error:"La lectura quedó incompleta. Revisá el archivo o cargá los datos manualmente."},422);
    const contents=(result.output??[]).flatMap((item:{content?:{type:string;text?:string}[]})=>item.content??[]);
    if(contents.some((item:{type:string})=>item.type==="refusal"))return reply({error:"No se pudo interpretar este documento como factura."},422);
    const text=contents.filter((item:{type:string})=>item.type==="output_text").map((item:{text:string})=>item.text).join("");
    return reply({draft:validateInvoiceDraft(JSON.parse(text),categories??[])});
  }catch(error){
    const message=error instanceof Error&&error.name==="TimeoutError"?"La lectura demoró demasiado. Podés reintentar o cargar manualmente.":"No se pudo leer la factura. Podés cargar los datos manualmente.";
    return reply({error:message},500);
  }
}
