import { CognitoIdentityProviderClient } from "@aws-sdk/client-cognito-identity-provider";
import { Route53Client } from "@aws-sdk/client-route-53";
import { S3Client } from "@aws-sdk/client-s3";
import { SESv2Client } from "@aws-sdk/client-sesv2";
import { SSMClient } from "@aws-sdk/client-ssm";

const region = process.env.AWS_REGION || "us-east-1";

export const cognitoClient = new CognitoIdentityProviderClient({ region });
export const route53Client = new Route53Client({ region });
export const s3Client = new S3Client({ region });
export const sesClient = new SESv2Client({ region });
export const ssmClient = new SSMClient({ region });
