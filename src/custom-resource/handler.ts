import {
  ChangeResourceRecordSetsCommand,
  ListHostedZonesByNameCommand,
} from "@aws-sdk/client-route-53";
import {
  DescribeUserPoolCommand,
  DescribeUserPoolDomainCommand,
  LambdaConfigType,
  UpdateUserPoolCommand,
} from "@aws-sdk/client-cognito-identity-provider";
import {
  CopyObjectCommand,
  DeleteObjectCommand,
  ListObjectsV2Command,
} from "@aws-sdk/client-s3";
import {
  DeleteParameterCommand,
  PutParameterCommand,
  SSMClient,
} from "@aws-sdk/client-ssm";
import {
  CreateEmailIdentityCommand,
  DeleteEmailIdentityCommand,
  GetEmailIdentityCommand,
} from "@aws-sdk/client-sesv2";
import { sendCloudFormationResponse } from "../shared/cfn-response";
import {
  cognitoClient,
  route53Client,
  s3Client,
  sesClient,
} from "../shared/aws-clients";

type Event = {
  RequestType: "Create" | "Update" | "Delete";
  ResourceProperties: Record<string, string>;
  OldResourceProperties?: Record<string, string>;
  PhysicalResourceId?: string;
  ResponseURL: string;
  StackId: string;
  RequestId: string;
  LogicalResourceId: string;
};

const CLOUDFRONT_ZONE_ID = "Z2FDTNDATAQYW2";
const ssmClient = new SSMClient({});

async function findHostedZoneId(fqdn: string): Promise<string | undefined> {
  const labels = fqdn.replace(/\.$/, "").split(".");
  for (let i = 0; i < labels.length - 1; i += 1) {
    const zoneName = `${labels.slice(i).join(".")}.`;
    const resp = await route53Client.send(
      new ListHostedZonesByNameCommand({ DNSName: zoneName, MaxItems: 10 }),
    );
    const zone = resp.HostedZones?.find((z) => z.Name === zoneName);
    if (zone?.Id) return zone.Id.replace("/hostedzone/", "");
  }
  return undefined;
}

async function upsertAliasRecords(
  hostedZoneId: string,
  recordName: string,
  aliasDnsName: string,
): Promise<void> {
  await route53Client.send(
    new ChangeResourceRecordSetsCommand({
      HostedZoneId: hostedZoneId,
      ChangeBatch: {
        Changes: ["A", "AAAA"].map((type) => ({
          Action: "UPSERT",
          ResourceRecordSet: {
            Name: recordName,
            Type: type,
            AliasTarget: {
              DNSName: aliasDnsName,
              HostedZoneId: CLOUDFRONT_ZONE_ID,
              EvaluateTargetHealth: false,
            },
          },
        })),
      },
    }),
  );
}

async function deleteAliasRecords(
  hostedZoneId: string,
  recordName: string,
  aliasDnsName: string,
): Promise<void> {
  await route53Client.send(
    new ChangeResourceRecordSetsCommand({
      HostedZoneId: hostedZoneId,
      ChangeBatch: {
        Changes: ["A", "AAAA"].map((type) => ({
          Action: "DELETE",
          ResourceRecordSet: {
            Name: recordName,
            Type: type,
            AliasTarget: {
              DNSName: aliasDnsName,
              HostedZoneId: CLOUDFRONT_ZONE_ID,
              EvaluateTargetHealth: false,
            },
          },
        })),
      },
    }),
  );
}

async function upsertCnameRecords(
  hostedZoneId: string,
  records: Array<{ name: string; value: string }>,
): Promise<void> {
  if (!records.length) return;
  await route53Client.send(
    new ChangeResourceRecordSetsCommand({
      HostedZoneId: hostedZoneId,
      ChangeBatch: {
        Changes: records.map((record) => ({
          Action: "UPSERT",
          ResourceRecordSet: {
            Name: record.name,
            Type: "CNAME",
            TTL: 300,
            ResourceRecords: [{ Value: record.value }],
          },
        })),
      },
    }),
  );
}

async function deleteCnameRecords(
  hostedZoneId: string,
  records: Array<{ name: string; value: string }>,
): Promise<void> {
  if (!records.length) return;
  await route53Client.send(
    new ChangeResourceRecordSetsCommand({
      HostedZoneId: hostedZoneId,
      ChangeBatch: {
        Changes: records.map((record) => ({
          Action: "DELETE",
          ResourceRecordSet: {
            Name: record.name,
            Type: "CNAME",
            TTL: 300,
            ResourceRecords: [{ Value: record.value }],
          },
        })),
      },
    }),
  );
}

async function handleHostedZoneLookup(props: Record<string, string>) {
  const hostedZoneId = await findHostedZoneId(props.DomainName);
  if (!hostedZoneId)
    throw new Error(`Hosted zone not found for domain: ${props.DomainName}`);
  return { HostedZoneId: hostedZoneId };
}

async function resolveAliasTarget(cognitoDomain: string): Promise<string> {
  const domainInfo = await cognitoClient.send(
    new DescribeUserPoolDomainCommand({ Domain: cognitoDomain }),
  );
  const aliasDnsName = domainInfo.DomainDescription?.CloudFrontDistribution;
  if (!aliasDnsName) {
    throw new Error(
      "Could not resolve Cognito custom domain CloudFront distribution",
    );
  }
  return aliasDnsName;
}

async function handleRoute53Alias(event: Event, props: Record<string, string>) {
  const aliasDnsName = await resolveAliasTarget(props.CognitoDomain);

  if (event.RequestType === "Delete") {
    try {
      await deleteAliasRecords(
        props.HostedZoneId,
        props.RecordName,
        aliasDnsName,
      );
    } catch {
      // best effort cleanup
    }
    return { AliasTarget: aliasDnsName };
  }

  if (
    event.RequestType === "Update" &&
    event.OldResourceProperties?.HostedZoneId &&
    event.OldResourceProperties?.RecordName &&
    (event.OldResourceProperties.HostedZoneId !== props.HostedZoneId ||
      event.OldResourceProperties.RecordName !== props.RecordName)
  ) {
    try {
      await deleteAliasRecords(
        event.OldResourceProperties.HostedZoneId,
        event.OldResourceProperties.RecordName,
        aliasDnsName,
      );
    } catch {
      // best effort cleanup of old record
    }
  }

  await upsertAliasRecords(props.HostedZoneId, props.RecordName, aliasDnsName);
  return { AliasTarget: aliasDnsName };
}

async function handleBucketCleaner(props: Record<string, string>) {
  const bucket = props.BucketName;
  const prefix = props.Prefix || "";
  let token: string | undefined;
  do {
    const page = await s3Client.send(
      new ListObjectsV2Command({
        Bucket: bucket,
        Prefix: prefix,
        ContinuationToken: token,
      }),
    );
    for (const obj of page.Contents || []) {
      if (obj.Key) {
        await s3Client.send(
          new DeleteObjectCommand({ Bucket: bucket, Key: obj.Key }),
        );
      }
    }
    token = page.NextContinuationToken;
  } while (token);
  return { CleanedBucket: bucket };
}

async function handleS3TemplateUpload(
  event: Event,
  props: Record<string, string>,
) {
  const destinationBucket = props.BucketName;
  const destinationPrefix = props.Prefix || "email-templates/";
  const sourceBucket = props.SourceBucketName;
  const sourcePrefix = props.SourcePrefix || "templates/email-templates/";

  if (event.RequestType === "Delete") {
    return { DeletedPrefix: destinationPrefix };
  }

  if (!sourceBucket) {
    throw new Error("SourceBucketName is required for S3TemplateUpload");
  }

  let token: string | undefined;
  let copied = 0;

  do {
    const page = await s3Client.send(
      new ListObjectsV2Command({
        Bucket: sourceBucket,
        Prefix: sourcePrefix,
        ContinuationToken: token,
      }),
    );

    for (const obj of page.Contents || []) {
      if (!obj.Key || obj.Key.endsWith("/")) continue;
      const relativeKey = obj.Key.startsWith(sourcePrefix)
        ? obj.Key.slice(sourcePrefix.length)
        : obj.Key;
      if (!relativeKey) continue;

      await s3Client.send(
        new CopyObjectCommand({
          Bucket: destinationBucket,
          Key: `${destinationPrefix}${relativeKey}`,
          CopySource: `${sourceBucket}/${encodeURIComponent(obj.Key).replace(/%2F/g, "/")}`,
          ContentType: "text/html; charset=utf-8",
          MetadataDirective: "REPLACE",
        }),
      );
      copied += 1;
    }

    token = page.NextContinuationToken;
  } while (token);

  return {
    UploadedPrefix: destinationPrefix,
    SourceBucket: sourceBucket,
    SourcePrefix: sourcePrefix,
    CopiedObjectCount: copied,
  };
}

async function handleSSMParameter(event: Event, props: Record<string, string>) {
  const name = props.Name;
  const value = props.Value || "";
  const keyId = props.KeyId || undefined;

  if (!name) {
    throw new Error("Name is required for SSMParameter");
  }

  if (event.RequestType === "Delete") {
    try {
      await ssmClient.send(new DeleteParameterCommand({ Name: name }));
    } catch {
      // best effort cleanup
    }
    return { Name: name };
  }

  await ssmClient.send(
    new PutParameterCommand({
      Name: name,
      Value: value,
      Type: "SecureString",
      Overwrite: true,
      KeyId: keyId,
    }),
  );

  return { Name: name };
}

function pruneUndefined<T extends object>(input: T): T {
  return Object.fromEntries(
    Object.entries(input).filter(([, v]) => v !== undefined),
  ) as T;
}

function setOrUnset(
  lambdaConfig: LambdaConfigType,
  key: keyof LambdaConfigType,
  value?: string,
) {
  if (value) {
    (lambdaConfig as Record<string, unknown>)[key] = value;
  } else {
    delete (lambdaConfig as Record<string, unknown>)[key];
  }
}

function parseList(value?: string): string[] {
  return (value || "")
    .split(",")
    .map((v) => v.trim())
    .filter(Boolean);
}

function parseBool(value?: string): boolean {
  return (value || "").toLowerCase() === "true";
}

function hasValue(list: string[], value: string): boolean {
  return list.includes(value);
}

function resolveVerificationAttributes(
  props: Record<string, string>,
): string[] {
  if (!parseBool(props.VerifyAttributeChanges)) return [];
  const mode = props.VerifyAttributeChangesMode || "auto";
  if (mode === "email") return ["email"];
  if (mode === "phone_number") return ["phone_number"];
  if (mode === "email_and_phone") return ["email", "phone_number"];
  if (parseBool(props.RequirePhoneNumberAttribute))
    return ["email", "phone_number"];
  return ["email"];
}

function resolveAutoVerifiedAttributes(
  props: Record<string, string>,
): string[] {
  const loginMechanisms = parseList(props.LoginMechanisms);
  const values: string[] = [];
  if (
    hasValue(loginMechanisms, "email") ||
    parseBool(props.RequireEmailAttribute) ||
    parseBool(props.EnableEmailOtpMfa)
  ) {
    values.push("email");
  }
  if (
    hasValue(loginMechanisms, "phone_number") ||
    parseBool(props.RequirePhoneNumberAttribute) ||
    parseBool(props.EnableSmsMfa)
  ) {
    values.push("phone_number");
  }
  return values;
}

function resolveRecoveryMechanisms(
  props: Record<string, string>,
  autoVerifiedAttributes: string[],
) {
  const recovery = [] as Array<{ Name: string; Priority: number }>;
  if (autoVerifiedAttributes.includes("email"))
    recovery.push({ Name: "verified_email", Priority: 1 });
  if (autoVerifiedAttributes.includes("phone_number"))
    recovery.push({
      Name: "verified_phone_number",
      Priority: recovery.length + 1,
    });
  return recovery;
}

function resolveEnabledMfas(props: Record<string, string>): string[] {
  const mode = props.MfaMode || "no";
  if (mode === "no") return [];
  const values: string[] = [];
  if (
    parseBool(props.EnableSoftwareTokenMfa) ||
    (!parseBool(props.EnableSmsMfa) && !parseBool(props.EnableEmailOtpMfa))
  ) {
    values.push("SOFTWARE_TOKEN_MFA");
  }
  if (parseBool(props.EnableEmailOtpMfa)) values.push("EMAIL_OTP");
  if (parseBool(props.EnableSmsMfa)) values.push("SMS_MFA");
  return values;
}

function resolveDeviceConfiguration(props: Record<string, string>) {
  const mode = props.DeviceTrackingMode || "none";
  const mfaMode = props.MfaMode || "no";
  if (mfaMode === "no" || mode === "none") return undefined;
  if (mode === "user_opt_in") {
    return {
      ChallengeRequiredOnNewDevice: true,
      DeviceOnlyRememberedOnUserPrompt: true,
    };
  }
  return {
    ChallengeRequiredOnNewDevice: true,
    DeviceOnlyRememberedOnUserPrompt: false,
  };
}

function resolveMfaConfiguration(mode?: string): "OFF" | "OPTIONAL" | "ON" {
  if (mode === "required") return "ON";
  if (mode === "optional") return "OPTIONAL";
  return "OFF";
}

async function updateUserPool(
  userPoolId: string,
  props: Record<string, string>,
  clear = false,
) {
  const userPoolResp = await cognitoClient.send(
    new DescribeUserPoolCommand({ UserPoolId: userPoolId }),
  );
  const userPool = userPoolResp.UserPool;
  if (!userPool) throw new Error(`User pool not found: ${userPoolId}`);

  const lambdaConfig: LambdaConfigType = { ...(userPool.LambdaConfig || {}) };

  setOrUnset(lambdaConfig, "PreSignUp", clear ? undefined : props.PreSignUpArn);
  setOrUnset(
    lambdaConfig,
    "PostConfirmation",
    clear ? undefined : props.PostConfirmationArn,
  );
  setOrUnset(
    lambdaConfig,
    "PreTokenGeneration",
    clear ? undefined : props.PreTokenGenerationArn,
  );

  if (!clear && props.CustomEmailSenderArn) {
    lambdaConfig.CustomEmailSender = {
      LambdaArn: props.CustomEmailSenderArn,
      LambdaVersion: "V1_0",
    };
    if (props.KmsKeyId) lambdaConfig.KMSKeyID = props.KmsKeyId;
    else delete lambdaConfig.KMSKeyID;
  } else if (clear) {
    delete lambdaConfig.CustomEmailSender;
    delete lambdaConfig.KMSKeyID;
  }

  const autoVerifiedAttributes = clear
    ? userPool.AutoVerifiedAttributes
    : resolveAutoVerifiedAttributes(props);
  const verificationAttributes = clear
    ? userPool.UserAttributeUpdateSettings
        ?.AttributesRequireVerificationBeforeUpdate
    : resolveVerificationAttributes(props);
  const enabledMfas = clear ? userPool.EnabledMfas : resolveEnabledMfas(props);
  const emailIdentity = !clear
    ? props.ResolvedSesIdentity || props.SesIdentity || undefined
    : undefined;
  const defaultFromAddress =
    props.EmailFromAddress ||
    ((props.ResolvedSesIdentity || props.SesIdentity || "").includes("@")
      ? props.ResolvedSesIdentity || props.SesIdentity
      : props.ResolvedSesIdentity || props.SesIdentity
        ? `no-reply@${props.ResolvedSesIdentity || props.SesIdentity}`
        : undefined);
  const fromAddress = !clear ? defaultFromAddress : undefined;
  const recoveryMechanisms = clear
    ? userPool.AccountRecoverySetting?.RecoveryMechanisms
    : resolveRecoveryMechanisms(props, autoVerifiedAttributes || []);

  const smsConfiguration =
    !clear &&
    parseBool(props.EnableSmsMfa) &&
    props.SmsConfigurationSnsCallerArn
      ? pruneUndefined({
          SnsCallerArn: props.SmsConfigurationSnsCallerArn,
          ExternalId: props.SmsConfigurationExternalId || undefined,
          SnsRegion: props.SmsConfigurationSnsRegion || undefined,
        })
      : userPool.SmsConfiguration;

  await cognitoClient.send(
    new UpdateUserPoolCommand(
      pruneUndefined({
        UserPoolId: userPoolId,
        Policies: userPool.Policies,
        AutoVerifiedAttributes: autoVerifiedAttributes,
        UsernameAttributes: userPool.UsernameAttributes,
        AliasAttributes: userPool.AliasAttributes,
        AdminCreateUserConfig: userPool.AdminCreateUserConfig,
        Schema: userPool.SchemaAttributes,
        MfaConfiguration: clear
          ? userPool.MfaConfiguration
          : resolveMfaConfiguration(props.MfaMode),
        EnabledMfas:
          enabledMfas && enabledMfas.length ? enabledMfas : undefined,
        VerificationMessageTemplate: userPool.VerificationMessageTemplate,
        UserAttributeUpdateSettings:
          verificationAttributes && verificationAttributes.length
            ? {
                AttributesRequireVerificationBeforeUpdate:
                  verificationAttributes,
              }
            : undefined,
        DeviceConfiguration: clear
          ? userPool.DeviceConfiguration
          : resolveDeviceConfiguration(props),
        EmailConfiguration: emailIdentity
          ? pruneUndefined({
              EmailSendingAccount: "DEVELOPER",
              SourceArn: `arn:${process.env.AWS_PARTITION || "aws"}:ses:${process.env.AWS_REGION}:${process.env.AWS_ACCOUNT_ID}:identity/${emailIdentity}`,
              From: fromAddress,
            })
          : userPool.EmailConfiguration,
        SmsConfiguration: smsConfiguration,
        UserPoolAddOns: userPool.UserPoolAddOns,
        AccountRecoverySetting:
          recoveryMechanisms && recoveryMechanisms.length
            ? { RecoveryMechanisms: recoveryMechanisms }
            : undefined,
        PoolName: userPool.Name,
        DeletionProtection: userPool.DeletionProtection,
        LambdaConfig: lambdaConfig,
      }),
    ),
  );
}

async function handleTriggerAttachment(
  event: Event,
  props: Record<string, string>,
) {
  const userPoolId = props.UserPoolId;
  if (event.RequestType === "Delete") {
    await updateUserPool(userPoolId, props, true);
    return { DetachedUserPoolId: userPoolId };
  }

  await updateUserPool(userPoolId, props, false);
  return { AttachedUserPoolId: userPoolId };
}

async function handleApplyUserPoolSettings(
  event: Event,
  props: Record<string, string>,
) {
  const userPoolId = props.UserPoolId;
  if (event.RequestType === "Delete") {
    return { UserPoolId: userPoolId };
  }
  await updateUserPool(userPoolId, props, false);
  return {
    UserPoolId: userPoolId,
    AutoVerifiedAttributes: resolveAutoVerifiedAttributes(props).join(","),
    EnabledMfas: resolveEnabledMfas(props).join(","),
  };
}

function toDkimRecords(
  identity: string,
  tokens: string[] | undefined,
): Array<{ name: string; value: string }> {
  return (tokens || []).filter(Boolean).map((token) => ({
    name: `${token}._domainkey.${identity}`,
    value: `${token}.dkim.amazonses.com`,
  }));
}

async function ensureEmailIdentity(identity: string) {
  try {
    return await sesClient.send(
      new GetEmailIdentityCommand({ EmailIdentity: identity }),
    );
  } catch {
    await sesClient.send(
      new CreateEmailIdentityCommand({ EmailIdentity: identity }),
    );
    return await sesClient.send(
      new GetEmailIdentityCommand({ EmailIdentity: identity }),
    );
  }
}

async function handleEnsureSesIdentity(
  event: Event,
  props: Record<string, string>,
) {
  const identity = props.Identity;
  if (!identity) throw new Error("Identity is required for EnsureSesIdentity");

  const hostedZoneId =
    props.HostedZoneId ||
    (parseBool(props.AutoDetectHostedZone)
      ? await findHostedZoneId(identity)
      : undefined);

  if (event.RequestType === "Delete") {
    try {
      const existing = await sesClient.send(
        new GetEmailIdentityCommand({ EmailIdentity: identity }),
      );
      const records = toDkimRecords(
        identity,
        (existing as any)?.DkimAttributes?.Tokens ||
          (existing as any)?.DkimAttributes?.tokens,
      );
      if (hostedZoneId && records.length) {
        try {
          await deleteCnameRecords(hostedZoneId, records);
        } catch {
          // best effort DNS cleanup
        }
      }
      if (parseBool(props.DeleteIdentityOnStackDelete)) {
        await sesClient.send(
          new DeleteEmailIdentityCommand({ EmailIdentity: identity }),
        );
      }
    } catch {
      // nothing to clean up
    }
    return { Identity: identity };
  }

  const resp = await ensureEmailIdentity(identity);
  const tokens = ((resp as any)?.DkimAttributes?.Tokens ||
    (resp as any)?.DkimAttributes?.tokens ||
    []) as string[];
  const records = toDkimRecords(identity, tokens);
  if (hostedZoneId && records.length) {
    await upsertCnameRecords(hostedZoneId, records);
  }

  return {
    Identity: identity,
    HostedZoneId: hostedZoneId || "",
    DkimTokens: tokens.join(","),
  };
}

export const handler = async (event: Event): Promise<void> => {
  const physicalId =
    event.PhysicalResourceId || `${event.LogicalResourceId}-${Date.now()}`;
  try {
    const type = event.ResourceProperties.Action;
    let data: Record<string, unknown> = {};

    switch (type) {
      case "SSMParameter":
        data = await handleSSMParameter(event, event.ResourceProperties);
        break;
      case "HostedZoneLookup":
        data = await handleHostedZoneLookup(event.ResourceProperties);
        break;
      case "Route53Alias":
        data = await handleRoute53Alias(event, event.ResourceProperties);
        break;
      case "BucketCleaner":
        if (event.RequestType === "Delete")
          data = await handleBucketCleaner(event.ResourceProperties);
        break;
      case "S3TemplateUpload":
        data = await handleS3TemplateUpload(event, event.ResourceProperties);
        break;
      case "TriggerAttachment":
        data = await handleTriggerAttachment(event, event.ResourceProperties);
        break;
      case "ApplyUserPoolSettings":
        data = await handleApplyUserPoolSettings(
          event,
          event.ResourceProperties,
        );
        break;
      case "EnsureSesIdentity":
        data = await handleEnsureSesIdentity(event, event.ResourceProperties);
        break;
      default:
        throw new Error(`Unsupported custom resource action: ${type}`);
    }

    await sendCloudFormationResponse({
      responseUrl: event.ResponseURL,
      status: "SUCCESS",
      physicalResourceId: physicalId,
      stackId: event.StackId,
      requestId: event.RequestId,
      logicalResourceId: event.LogicalResourceId,
      data,
    });
  } catch (error) {
    await sendCloudFormationResponse({
      responseUrl: event.ResponseURL,
      status: "FAILED",
      physicalResourceId: physicalId,
      stackId: event.StackId,
      requestId: event.RequestId,
      logicalResourceId: event.LogicalResourceId,
      reason: error instanceof Error ? error.message : String(error),
    });
  }
};
