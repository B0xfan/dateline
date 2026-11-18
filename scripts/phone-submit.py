# /// script
# dependencies = ["pyjwt[crypto]", "requests"]
# ///
"""Sends the iPhone app's current version to App Store review, then raises the project's version number.

    uv run scripts/phone-submit.py "What is new, one line per change"            dry run: checks only, changes nothing
    uv run scripts/phone-submit.py "What is new, one line per change" --submit   creates the version, attaches the build,
                                                                                  submits it, then raises the number and pushes (a rerun after a failed push only does the raise)
Why the raise: Apple closes a number for uploads once it is in review or live, and every push to main uploads.
Raising the number in the same step as the submit means no later upload can ever carry a closed number.
iPad pictures: a version with no 13 inch iPad pictures gets them from a passing cloud check of this exact commit (scripts/cloud-build.sh),
through Apple's asset library. Apple copies pictures to the next version, so this normally runs once.
App Store review only, never TestFlight.
"""
import atexit, os, re, shutil, subprocess, sys, tempfile, time
import jwt, requests

APP = "6831255878"
KEY_ID = "S93537G5A5"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBX = os.path.join(ROOT, "iPhone/Dateline.xcodeproj/project.pbxproj")
API = "https://api.appstoreconnect.apple.com/v1"
PAD_GROUP = "IPAD_13_PROFILE"  # Apple's 13 inch iPad screenshot group (appAssetLibraryRefData)
PAD_SHOTS = ["week", "week-sideways", "day", "month", "tasks", "add", "details", "settings"]  # light pictures, store order


def next_version(v):
    major, minor = v.split(".")[:2]
    return f"{major}.{int(minor) + 1}"


def issuer():
    if os.environ.get("ASC_ISSUER_ID"):
        return os.environ["ASC_ISSUER_ID"]
    for line in open(os.path.expanduser("~/Projects/A4/.env")):
        if line.startswith("ASC_ISSUER_ID="):
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit("ASC_ISSUER_ID not found in the environment or A4/.env")


def call(method, path, **kw):
    key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")).read()
    now = int(time.time())
    tok = jwt.encode({"iss": issuer(), "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}, key,
                     algorithm="ES256", headers={"kid": KEY_ID})
    r = requests.request(method, API + path, headers={"Authorization": "Bearer " + tok}, timeout=60, **kw)
    if r.status_code >= 400:
        sys.exit(f"{method} {path} failed ({r.status_code}): {r.text[:800]}")
    return r.json() if r.text else {}


def pad_placed(loc):
    placed = call("GET", f"/appStoreVersionLocalizations/{loc['id']}/placements", params={
        "filter[placementType]": "APP_SCREENSHOT", "filter[placementGroup]": PAD_GROUP, "limit": 50})["data"]
    return [p for p in placed if p["attributes"]["placementGroup"] == PAD_GROUP]  # never count or delete the iPhone or Watch pictures


def pad_missing(vid):
    """The version's localizations without a full set of iPad pictures (a stopped run can leave part of one)."""
    return [loc for loc in call("GET", f"/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]
            if len(pad_placed(loc)) != len(PAD_SHOTS)]


def pad_pictures(dest):
    """The iPad pictures from a passing cloud check of this exact commit, as JPEGs (Apple refuses see-through PNGs), checked for size."""
    head = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    run = subprocess.run(["gh", "run", "list", "--workflow", "build.yml", "--status", "success", "--commit", head, "--limit", "1",
                          "--json", "databaseId", "-q", ".[0].databaseId"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    if not run:
        sys.exit(f"No passing cloud check of {head[:7]} to take the iPad pictures from. Run scripts/cloud-build.sh first.")
    if subprocess.run(["gh", "run", "download", run, "--name", "ios-shots", "--dir", dest], cwd=ROOT).returncode:
        sys.exit(f"Cloud check {run} has no pictures left (they are kept 3 days). Run scripts/cloud-build.sh again.")
    out = []
    for s in PAD_SHOTS:
        png, jpg = f"{dest}/ipad/{s}-light.png", f"{dest}/{s}.jpg"
        if not os.path.exists(png):
            sys.exit(f"Cloud check {run} has no iPad picture {s}-light.png.")
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "90", png, "--out", jpg], capture_output=True, check=True)
        dims = re.findall(r"pixel(?:Width|Height): (\d+)", subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", jpg],
                                                                         capture_output=True, text=True).stdout)
        if sorted(dims) != ["2064", "2752"]:
            sys.exit(f"{s}: {'x'.join(dims)} is not a 13 inch iPad picture (2064 x 2752).")
        out.append(jpg)
    print(f"iPad pictures: {len(out)} from cloud check {run}")
    return out


def upload_image(lib, path):
    """Reserve, send and commit one picture in the app's asset library; returns its id."""
    img = call("POST", "/appAssetLibraryImages", json={"data": {"type": "appAssetLibraryImages",
        "attributes": {"fileName": os.path.basename(path), "fileSize": os.path.getsize(path),
                       "category": "APP_SCREENSHOTS_AND_PREVIEWS", "referenceName": "iPad 13 " + os.path.basename(path)},
        "relationships": {"assetLibrary": {"data": {"type": "appAssetLibraries", "id": lib}}}}})["data"]
    data = open(path, "rb").read()
    for op in img["attributes"]["uploadOperations"]:  # Apple's own upload addresses: no sign-in sent
        r = requests.request(op["method"], op["url"], data=data[op["offset"]:op["offset"] + op["length"]], timeout=300,
                             headers={h["name"]: h["value"] for h in op.get("requestHeaders") or []})
        if r.status_code >= 400:
            sys.exit(f"Sending {path} failed ({r.status_code}): {r.text[:300]}")
    call("PATCH", f"/appAssetLibraryImages/{img['id']}", json={"data": {"type": "appAssetLibraryImages", "id": img["id"],
                                                                         "attributes": {"uploaded": True}}})
    return img["id"]


def wait_processed(ids, minutes=10):
    left = set(ids)
    for _ in range(minutes * 6):
        for i in sorted(left):
            a = call("GET", f"/appAssetLibraryImages/{i}", params={"fields[appAssetLibraryImages]": "state,stateDetails,fileName"})["data"]["attributes"]
            if a["state"] == "FAILED":
                sys.exit(f"Apple could not process {a['fileName']}: {a.get('stateDetails')}")
            if a["state"] in ("PREPARE_FOR_SUBMISSION", "APPROVED"):
                left.discard(i)
        if not left:
            return
        time.sleep(10)
    sys.exit(f"Apple was still processing {len(left)} iPad pictures after {minutes} minutes. Run the submit again.")


def add_pad_pictures(locs, files):
    lib = call("GET", f"/apps/{APP}/assetLibrary")["data"]["id"]
    ids = [upload_image(lib, f) for f in files]
    wait_processed(ids)
    # shortcut: a rerun uploads the 8 pictures again, leaving the earlier copies unused in the library; harmless clutter.
    for loc in locs:
        for old in pad_placed(loc):  # a part set from a stopped run is replaced whole
            call("DELETE", f"/appAssetLibraryPlacements/{old['id']}")
        placed = [call("POST", "/appAssetLibraryPlacements", json={"data": {"type": "appAssetLibraryPlacements",
            "attributes": {"placementType": "APP_SCREENSHOT", "placementGroup": PAD_GROUP},
            "relationships": {"image": {"data": {"type": "appAssetLibraryImages", "id": i}},
                              "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]["id"]
                  for i in ids]
        call("POST", "/appAssetLibraryPlacementOrderingRequests", json={"data": {"type": "appAssetLibraryPlacementOrderingRequests",
            "attributes": {"placementGroup": PAD_GROUP},
            "relationships": {"orderedPlacements": {"data": [{"type": "appAssetLibraryPlacements", "id": p} for p in placed]},
                              "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})
        print(f"iPad pictures placed on {loc['attributes']['locale']}.")


def raise_and_push(text, version):
    nxt = next_version(version)
    open(PBX, "w").write(text.replace(f"MARKETING_VERSION = {version};", f"MARKETING_VERSION = {nxt};"))
    git = ["git", "-C", ROOT]
    subprocess.run(git + ["commit", "-qm", f"iPhone {nxt}: {version} is in App Store review, so uploads move to the next number",
                          "iPhone/Dateline.xcodeproj/project.pbxproj"], check=True)
    subprocess.run(git + ["pull", "-q", "--rebase", "origin", "main"], check=True)
    subprocess.run(git + ["push", "-q", "origin", "HEAD:main"], check=True)
    print(f"Project raised to {nxt} and pushed.")


def main():
    assert next_version("1.7") == "1.8" and next_version("1.9") == "1.10" and next_version("2.0.1") == "2.1"
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        sys.exit(__doc__)
    notes, submit = sys.argv[1].strip(), "--submit" in sys.argv[2:]

    if submit:  # a raise committed by an earlier run whose push failed goes out first
        git = ["git", "-C", ROOT]
        subprocess.run(git + ["pull", "-q", "--rebase", "origin", "main"], check=True)
        subprocess.run(git + ["push", "-q", "origin", "HEAD:main"], check=True)
    text = open(PBX).read()
    found = set(re.findall(r"MARKETING_VERSION = ([0-9.]+);", text))
    if len(found) != 1:
        sys.exit(f"The project's targets disagree on the version: {sorted(found)}")
    version = found.pop()

    # A version already in review or on sale is closed: submitting it again would fail.
    def versions(**f):
        return call("GET", f"/apps/{APP}/appStoreVersions", params={"filter[platform]": "IOS", "limit": 200,
                    "fields[appStoreVersions]": "versionString,appStoreState", **f})["data"]
    mine = next(iter(versions(**{"filter[versionString]": version})), None)
    state = mine["attributes"]["appStoreState"] if mine else None
    if state and state not in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
        # A rerun after a failed push lands here: finish the raise instead of stopping.
        print(f"Version {version} is already {state}.")
        if submit:
            raise_and_push(text, version)
        return
    pending = [v["attributes"]["versionString"] for v in
               versions(**{"filter[appStoreState]": "WAITING_FOR_REVIEW,IN_REVIEW,PENDING_DEVELOPER_RELEASE"})]
    if pending:
        sys.exit(f"Version {', '.join(pending)} is still with Apple. Apple allows one version in review at a time.")

    builds = call("GET", "/builds", params={"filter[app]": APP, "filter[preReleaseVersion.version]": version,
                                           "filter[processingState]": "VALID", "sort": "-uploadedDate", "limit": 1,
                                           "fields[builds]": "version,uploadedDate"})["data"]
    if not builds:
        sys.exit(f"No finished upload of {version} yet. Wait for the cloud build to reach Apple.")
    build = builds[0]
    print(f"Ready: version {version}, build {build['attributes']['version']} "
          f"(uploaded {build['attributes']['uploadedDate']}), App Store state now: {state or 'not created'}")
    print(f"After the submit the project moves to {next_version(version)}.")
    shots = tempfile.mkdtemp(prefix="dateline-ipad-")
    atexit.register(shutil.rmtree, shots, True)
    pad = pad_missing(mine["id"]) if mine else None  # a new version gets Apple's copy of the last one's pictures first
    files = pad_pictures(shots) if pad else None  # checked in the dry run too, so a missing picture shows before anything is sent
    if not submit:
        print("iPad pictures: " + ("would be added." if pad else "already on the version." if mine else "checked once Apple makes the version."))
        print("Dry run: nothing changed. Add --submit to send it.")
        return

    if not mine:
        mine = call("POST", "/appStoreVersions", json={"data": {"type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": version},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
    vid = mine["id"]
    call("PATCH", f"/appStoreVersions/{vid}/relationships/build", json={"data": {"type": "builds", "id": build["id"]}})
    pad = pad_missing(vid)
    if pad:
        add_pad_pictures(pad, files or pad_pictures(shots))
    for loc in call("GET", f"/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]:
        call("PATCH", f"/appStoreVersionLocalizations/{loc['id']}", json={"data": {
            "type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"whatsNew": notes}}})
    # Apple keeps one open submission per platform; a run that stopped partway left one, so reuse it.
    open_subs = call("GET", "/reviewSubmissions", params={"filter[app]": APP, "filter[platform]": "IOS",
                     "filter[state]": "READY_FOR_REVIEW", "include": "items", "limit": 1})
    sub = next(iter(open_subs["data"]), None) or call("POST", "/reviewSubmissions", json={"data": {
        "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
    if not sub.get("relationships", {}).get("items", {}).get("data"):
        call("POST", "/reviewSubmissionItems", json={"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
            "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    call("PATCH", f"/reviewSubmissions/{sub['id']}", json={"data": {"type": "reviewSubmissions", "id": sub["id"],
        "attributes": {"submitted": True}}})
    print(f"Submitted {version} for App Store review.")

    raise_and_push(text, version)

if __name__ == "__main__":
    main()
