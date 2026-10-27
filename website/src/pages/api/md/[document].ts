import type { APIRoute } from "astro";
import { markdownIdentity, markdownRoutes } from "../../../config/markdown-documents";
export function getStaticPaths() {
 return [{ params: { document: "_identity" }, props: { data: markdownIdentity } }, { params: { document: "_catalog" }, props: { data: markdownRoutes } }];
}
export const GET: APIRoute = ({ props }) => Response.json(props.data);
