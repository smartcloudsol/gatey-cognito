# WP Suite Cognito Infrastructure

Reusable AWS Serverless Application Repository (SAR) application for deploying the Cognito-based authentication foundation used across WP Suite plugins, including Gatey, AI-Kit, and Flow.

This backend is intended for customers who want WP Suite authentication components to run in **their own AWS account**. It can create a new Cognito foundation from scratch or attach selected capabilities to an existing user pool.



## Why this stack matters across WP Suite

This application is more than a basic user pool template. It establishes the **shared authentication backbone** that other WP Suite backends can build on.

When a user signs in through Gatey on a WordPress site, Gatey-driven frontend and admin requests can automatically carry the required **Cognito JWT** or **IAM-backed** credentials. That allows other WP Suite backends, such as **Flow** and **AI-Kit**, to protect their own APIs with Cognito authorizers or IAM authorization **without building a separate authentication layer from scratch**.

A particularly important capability is the optional **pre token generation** trigger. It can enrich issued access tokens with custom scopes derived from the user's Cognito group memberships, for example scopes in the form:

- `sc.group.admin`
- `sc.group.editors`
- `sc.group.members`

These scopes can then be referenced by Flow and AI-Kit backend deployments to protect selected admin or frontend endpoints not only for authenticated users in general, but for specific roles or groups as well.

In practice, this means you can:

- sign users in once through Gatey
- reuse the same Cognito foundation across WP Suite plugins
- protect downstream APIs with **IAM**, **Cognito**, or **group-based custom scopes**
- keep the entire authentication and authorization backbone in the customer's own AWS account

## What this application provides

Depending on the selected parameters, this application can provision and configure:

- A **Cognito User Pool** with a default app client
- An optional **Cognito custom domain** for managed login
- Optional **Route 53 alias records** for the Cognito domain
- An optional **Cognito Identity Pool** with IAM roles for authenticated identities
- Optional **Lambda triggers** for sign-up validation, token customization, post-confirmation processing, and custom email delivery
- Optional **SES-backed custom email sending**
- Optional **S3-hosted HTML email templates**, copied from the packaged SAR artifacts during deployment
- Optional **reCAPTCHA validation** in the pre sign-up flow
- Common user-pool settings such as login mechanisms, MFA, attribute requirements, and verification behavior

## Typical use cases

This application is a good fit when you want to:

- deploy the authentication backend required by **Gatey**, **AI-Kit**, or **Flow**
- standardize authentication infrastructure across multiple WP Suite plugins
- create a reusable Cognito setup in a customer-owned AWS account
- use Cognito Lambda triggers without manually wiring them one by one
- send branded transactional emails from SES with HTML templates stored in S3
- enable advanced sign-up or token customization logic while keeping the infrastructure serverless and reproducible

## Main building blocks

### Cognito foundation

The stack can create a new Cognito user pool and app client, or attach trigger-based functionality to an existing user pool.

The created user pool is configured with strong password policy, advanced security mode, optional required attributes, optional MFA-related settings, and optional custom domain support. A default app client is also created for OAuth-based sign-in flows.

### Identity layer

When enabled together with a newly created user pool, the stack can also create a Cognito identity pool and IAM roles for authenticated users.

This is useful when authenticated WP Suite users need AWS-backed identities or controlled access to downstream APIs.

### Trigger-based extensibility

Optional Lambda triggers can be enabled to extend Cognito behavior:

- **Pre sign-up** for validation and automated identity-provider linking
- **Pre token generation** for token customization
- **Post confirmation** for user bootstrap tasks such as assigning a default group
- **Custom email sender** for SES-based transactional email delivery

This makes the stack suitable not only for login itself, but also for more advanced onboarding and account lifecycle workflows.

### Email delivery and templates

If custom email sending is enabled, the stack can:

- provision or reuse an S3 bucket for HTML templates
- copy packaged templates into that bucket at deployment time
- configure SES identity usage
- route Cognito emails through a Lambda-based custom sender

This allows WP Suite plugins to use branded transactional emails without hard-coding templates into the Lambda packages.

### Domain and DNS automation

If you provide a custom domain and certificate, the stack can configure a Cognito custom domain and optionally create Route 53 alias records for it.

For Cognito custom domains, the ACM certificate must be issued in **us-east-1**.

## Main configuration areas

The most important parameter groups are:

### Core deployment mode

- `CreateUserPool`
- `ExistingUserPoolId`
- `CreateIdentityPool`
- `CreateCustomDomain`
- `RegisterRoute53Alias`

### Login and OAuth behavior

- `PostLoginRedirectUrl`
- `OAuthScopes`
- `LoginMechanisms`
- `RequireEmailAttribute`
- `RequireGivenNameAttribute`
- `RequireFamilyNameAttribute`
- `RequirePhoneNumberAttribute`

### Identity pool

- `IdentityPoolName`
- `AllowUnauthenticatedIdentities`

### Triggers

- `EnablePreSignUp`
- `EnablePreTokenGeneration`
- `EnablePostConfirmation`
- `EnableCustomEmailSender`

### Email templates and SES

- `EmailTemplateBucketName`
- `AutoCreateSesIdentity`
- `DeleteSesIdentityOnStackDelete`
- `SesIdentity`
- `EmailFromAddress`
- `CallbackBaseUrl`
- `SubjectTemplate*`

### Email delivery modes

This stack supports two email modes:

- **Cognito-managed email**: the simpler default path for standard Cognito emails.
- **SES-backed HTML email**: required when you want custom HTML email templates and fully custom subject lines.

If you enable HTML email delivery, provide an already verified SES identity for the most predictable deployment, or allow the stack to create the identity resource for you. Automatic creation does not guarantee that the identity is immediately verified and usable.

If you enable **Email OTP MFA**, Amazon Cognito still requires SES-backed developer email configuration for that part of the flow, even if you otherwise prefer the simpler Cognito-managed email path.

### Security features

- `EnableRecaptcha`
- `RecaptchaMode`
- `RecaptchaProjectId`
- `RecaptchaSiteKey`
- `RecaptchaSecretKey`
- `RecaptchaScoreThreshold`
- `MfaMode`
- `EnableSoftwareTokenMfa`
- `EnableEmailOtpMfa`
- `EnableSmsMfa`
- `DeviceTrackingMode`

## Important notes and limitations

- **Custom domain certificates must be in us-east-1.**
- The stack supports attaching triggers to an **existing user pool**.
- Identity pool creation is currently wired to the **newly created** user pool/client path. Creating an identity pool for an already existing user pool is not yet covered by this version.
- The Cognito custom email sender replaces the default Cognito email transport, so SES-related settings should be reviewed carefully before enabling it.
- For the most reliable SES-backed deployments, pre-create and verify the SES identity before launching the stack.
- If reCAPTCHA is enabled and a secret is supplied, the secret is stored in **SSM Parameter Store** as a secure string.
- When the stack creates its own email template bucket, the deployment also includes helper logic to upload templates and clean up bucket contents when appropriate.

## Outputs

Depending on the chosen configuration, the stack can return outputs such as:

- User pool ID and ARN
- User pool client ID
- User pool domain
- Identity pool ID
- IAM role ARNs
- Trigger Lambda ARNs
- Email template bucket name
- Resolved SES identity

## Who this is for

This application is intended for WP Suite customers, partners, and advanced implementers who want a reusable, serverless authentication backbone in their own AWS environment.

In practical terms:

- **Gatey** uses it as a Cognito foundation for WordPress authentication and protected user flows
- **AI-Kit** can reuse the same authentication layer to protect admin and frontend APIs with Cognito or IAM, using Gatey-issued tokens and optional group-based custom scopes
- **Flow** can build on the same shared authentication infrastructure to secure admin or frontend APIs, including role-aware protection based on Cognito group-derived scopes

## Summary

**Sign users in once through Gatey, then secure Flow, AI-Kit, and other WP Suite backend APIs with Cognito, IAM, and group-based scopes in your own AWS account.**
