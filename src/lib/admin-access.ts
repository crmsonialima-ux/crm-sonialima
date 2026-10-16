export const RESTRICTED_ADMIN_EMAIL = "";
export const ADMINISTRATOR_ADMIN_ID = "37094db7-2457-48f2-8573-40c887e547e5";
export const VITOR_EMAIL = "unassigned-operator@example.invalid";

type ProfileLike = {
  id?: string | null;
  role?: string | null;
  email?: string | null;
};

export function isRestrictedAdmin(profile?: ProfileLike | null) {
  return (
    profile?.role === "admin" &&
    profile.email?.trim().toLocaleLowerCase("pt-BR") === RESTRICTED_ADMIN_EMAIL
  );
}

export function hasFullAdminAccess(profile?: ProfileLike | null) {
  return isAdministradorAdmin(profile);
}

export function isAdministradorAdmin(profile?: ProfileLike | null) {
  return (
    profile?.role === "admin" &&
    profile.id === ADMINISTRATOR_ADMIN_ID
  );
}

export function canViewExecutiveDashboard(profile?: ProfileLike | null) {
  return (
    isAdministradorAdmin(profile) ||
    profile?.email?.trim().toLocaleLowerCase("pt-BR") === "crmsonia@gmail.com"
  );
}

export function isVitorProfile(profile?: ProfileLike | null) {
  return profile?.email?.trim().toLocaleLowerCase("pt-BR") === VITOR_EMAIL;
}

export function canEditPropertyPortalCodes(profile?: ProfileLike | null) {
  return isAdministradorAdmin(profile);
}
