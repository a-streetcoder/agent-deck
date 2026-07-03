// Single import point for pi's wire types. Everything protocol-shaped must come from
// the pinned @earendil-works/pi-coding-agent package — never hand-rolled — so a pi
// upgrade turns protocol drift into compile errors.
export type {
  RpcCommand,
  RpcResponse,
  RpcSessionState,
  RpcExtensionUIRequest,
  RpcExtensionUIResponse,
  SessionEntry,
} from "@earendil-works/pi-coding-agent";
