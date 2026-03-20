import https from "node:https";
import { URL } from "node:url";

export async function sendCloudFormationResponse(params: {
  responseUrl: string;
  status: "SUCCESS" | "FAILED";
  physicalResourceId: string;
  stackId: string;
  requestId: string;
  logicalResourceId: string;
  data?: Record<string, unknown>;
  reason?: string;
}): Promise<void> {
  const body = JSON.stringify({
    Status: params.status,
    Reason: params.reason ?? "See CloudWatch Logs for details.",
    PhysicalResourceId: params.physicalResourceId,
    StackId: params.stackId,
    RequestId: params.requestId,
    LogicalResourceId: params.logicalResourceId,
    Data: params.data ?? {},
  });

  const url = new URL(params.responseUrl);
  await new Promise<void>((resolve, reject) => {
    const req = https.request(
      {
        hostname: url.hostname,
        path: `${url.pathname}${url.search}`,
        method: "PUT",
        headers: {
          "content-type": "",
          "content-length": Buffer.byteLength(body),
        },
      },
      (res) => {
        res.on("data", () => undefined);
        res.on("end", () => resolve());
      },
    );
    req.on("error", reject);
    req.write(body);
    req.end();
  });
}
