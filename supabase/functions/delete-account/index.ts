import { createClient } from "npm:@supabase/supabase-js@2";

const jsonHeaders = { "content-type": "application/json; charset=utf-8", "vary": "Origin" };

Deno.serve(async (request) => {
  const origin = request.headers.get("origin");
  const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN");

  if (!allowedOrigin || !origin || origin !== allowedOrigin) {
    return new Response(JSON.stringify({ error: "Origin is not allowed." }), {
      status: 403,
      headers: jsonHeaders
    });
  }

  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: {
        ...jsonHeaders,
        "access-control-allow-origin": allowedOrigin,
        "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
        "access-control-allow-methods": "POST, OPTIONS",
        "access-control-max-age": "86400"
      }
    });
  }

  if (request.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed." }), {
      status: 405,
      headers: { ...jsonHeaders, "access-control-allow-origin": allowedOrigin }
    });
  }

  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return new Response(JSON.stringify({ error: "Sign in again to delete your account." }), {
      status: 401,
      headers: { ...jsonHeaders, "access-control-allow-origin": allowedOrigin }
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return new Response(JSON.stringify({ error: "Account deletion is not configured." }), {
      status: 503,
      headers: { ...jsonHeaders, "access-control-allow-origin": allowedOrigin }
    });
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false }
  });
  const accessToken = authorization.slice("Bearer ".length);
  const { data: { user }, error: userError } = await userClient.auth.getUser(accessToken);
  if (userError || !user) {
    return new Response(JSON.stringify({ error: "Your session is invalid. Sign in again." }), {
      status: 401,
      headers: { ...jsonHeaders, "access-control-allow-origin": allowedOrigin }
    });
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false }
  });
  const { data: documents, error: documentsError } = await adminClient
    .from("loan_documents")
    .select("storage_path")
    .eq("owner_id", user.id);
  if (documentsError) {
    return new Response(JSON.stringify({ error: "We could not safely remove your private files. Please try again or contact support." }), {
      status: 500,
      headers: { ...jsonHeaders, "access-control-allow-origin": allowedOrigin }
    });
  }

  const documentRows = documents ?? [];
  for (let index = 0; index < documentRows.length; index += 100) {
    const paths = documentRows.slice(index, index + 100).map((document) => document.storage_path);
    const { error: storageError } = await adminClient.storage
      .from("paymeback-loan-documents")
      .remove(paths);
    if (storageError) {
      return new Response(JSON.stringify({ error: "We could not safely remove your private files. Please try again or contact support." }), {
        status: 500,
        headers: { ...jsonHeaders, "access-control-allow-origin": allowedOrigin }
      });
    }
  }

  const { error: deleteError } = await adminClient.auth.admin.deleteUser(user.id);
  if (deleteError) {
    return new Response(JSON.stringify({ error: "We could not delete your account. Please try again or contact support." }), {
      status: 500,
      headers: { ...jsonHeaders, "access-control-allow-origin": allowedOrigin }
    });
  }

  return new Response(JSON.stringify({ deleted: true }), {
    status: 200,
    headers: { ...jsonHeaders, "access-control-allow-origin": allowedOrigin }
  });
});
