xquery version "3.0";

module namespace scanrepo="http://exist-db.org/xquery/admin/scanrepo";

import module namespace config="http://exist-db.org/xquery/apps/config" at "config.xqm";

declare namespace repo="http://exist-db.org/xquery/repo";
declare namespace expath="http://expath.org/ns/pkg";

declare function scanrepo:process($apps as element(app)*) {
    for $app in $apps
    group by $name := $app/name
    return
        let $newest := scanrepo:find-newest($app, ())
        return
            <app>
                { $newest/@*, $newest/* }
                <other>
                {
                    for $older in $app[version != $newest/version]
                    return
                        <version version="{$older/version}">{$older/@path}</version>
                }
                </other>
            </app>
};

declare function scanrepo:find-newest($apps as element()*, $newest as element(app)?) {
    if (empty($apps)) then
        $newest
    else
        let $app := head($apps)
        let $newer :=
            if (empty($newest) or scanrepo:is-newer(($app/version, $app/@version), ($newest/version, $newest/@version))) then
                $app
            else
                $newest
        return
            scanrepo:find-newest(tail($apps), $newer)
};

declare function scanrepo:find-version($apps as element()*, $minVersion as xs:string?, $maxVersion as xs:string?) {
    let $minVersion := if ($minVersion) then $minVersion else "0"
    let $maxVersion := if ($maxVersion) then $maxVersion else "9999"
    return
        scanrepo:find-version($apps, $minVersion, $maxVersion, ())
};

declare %private function scanrepo:find-version($apps as element()*, $minVersion as xs:string, $maxVersion as xs:string, $newest as element()?) {
    if (empty($apps)) then
        $newest
    else
        let $app := head($apps)
        let $appVersion := $app/version | $app/@version
        let $newer :=
            if (
                (empty($newest) or scanrepo:is-newer($appVersion, ($newest/version, $newest/@version))) and
                scanrepo:is-newer($appVersion, $minVersion) and
                scanrepo:is-older($appVersion, $maxVersion)
            ) then
                $app
            else
                $newest
        return
            scanrepo:find-version(tail($apps), $minVersion, $maxVersion, $newer)
};

declare %private function scanrepo:is-newer($available as xs:string, $installed as xs:string) as xs:boolean {
    let $verInstalled := tokenize($installed, "\.")
    let $verAvailable := tokenize($available, "\.")
    return
        scanrepo:compare-versions($verInstalled, $verAvailable, function($version1, $version2) {
            number($version1) >= number($version2)
        })
};

declare %private function scanrepo:is-older($available as xs:string, $installed as xs:string) as xs:boolean {
    let $verInstalled := tokenize($installed, "\.")
    let $verAvailable := tokenize($available, "\.")
    return
        scanrepo:compare-versions($verInstalled, $verAvailable, function($version1, $version2) {
            number($version1) <= number($version2)
        })
};

declare %private function scanrepo:compare-versions($installed as xs:string*, $available as xs:string*,
    $compare as function(*)) as xs:boolean {
    if (empty($installed)) then
        exists($available)
    else if (empty($available)) then
        false()
    else if (head($available) = head($installed)) then
        if (count($available) = 1 and count($installed) = 1) then
            true()
        else
            scanrepo:compare-versions(tail($installed), tail($available), $compare)
    else
        $compare(head($available), head($installed))
};

declare function scanrepo:entry-data($path as xs:anyURI, $type as xs:string, $data as item()?, $param as item()*) as item()*
{
    if (starts-with($path, "icon")) then
        let $pkgName := substring-before($param, ".xar")
        let $suffix := replace($path, "^.*\.([^\.]+)", "$1")
        let $name := concat($pkgName, ".", $suffix)
        let $stored :=
            xmldb:store($config:public, $name, $data)
        return
            <icon>{ $name }</icon>
    else
        let $root := $data/*
        return
            typeswitch ($root)
                case element(expath:package) return (
                    <name>{$root/@name/string()}</name>,
                    <title>{$root/expath:title/text()}</title>,
                    <abbrev>{$root/@abbrev/string()}</abbrev>,
                    <version>{$root/@version/string()}</version>,
                    if ($root/expath:dependency[@processor = "eXist-db"]/@version) then
                        <requires>{ $root/expath:dependency[@processor = "eXist-db"]/@version }</requires>
                    else
                        ()
                )
                case element(repo:meta) return (
                    for $author in $root/repo:author
                    return
                        <author>{$author/text()}</author>,
                    <description>{$root/repo:description/text()}</description>,
                    <website>{$root/repo:website/text()}</website>,
                    <license>{$root/repo:license/text()}</license>,
                    <type>{$root/repo:type/text()}</type>,
                    for $note in $root/repo:note
                    return
                        <note>{$note/text()}</note>,
                    <changelog>
                    {
                        for $change in $root/repo:changelog/repo:change
                        return
                            <change version="{$change/@version}">
                            { $change/node() }
                            </change>
                    }
                    </changelog>
                )
                default return
                    ()
};

declare function scanrepo:entry-filter($path as xs:anyURI, $type as xs:string, $param as item()*) as xs:boolean
{
    starts-with($path, "icon.") or $path = ("repo.xml", "expath-pkg.xml")
};

declare function scanrepo:extract-metadata($resource as xs:string) {
    let $xar := concat($config:public, "/", $resource)
    return
        <app path="{$resource}" size="{xmldb:size($config:public, $resource)}">
        {
            compression:unzip(util:binary-doc($xar), util:function(xs:QName("scanrepo:entry-filter"), 3), (),  
                util:function(xs:QName("scanrepo:entry-data"), 4), $resource)
        }
        </app>
};

declare function scanrepo:scan-all() {
    for $resource in xmldb:get-child-resources($config:public)
    where ends-with($resource, ".xar")
    return
        scanrepo:extract-metadata($resource)
};

declare function scanrepo:scan() {
    let $data := scanrepo:scan-all()
    let $processed := scanrepo:process($data)
    return
        xmldb:store($config:public, "apps.xml", <apps> { $processed }</apps>)
};