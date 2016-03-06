/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

module ag.handler.desktopparser;

import std.path : baseName;
import std.uni : toLower;
import std.string : format, indexOf;
import std.algorithm : startsWith, split, strip, stripRight;
import std.stdio;
import glib.KeyFile;
import appstream.Component;
import appstream.Provided;
import appstream.Icon;

import ag.result;
import ag.utils;


immutable DESKTOP_GROUP = "Desktop Entry";

private string getLocaleFromKey (string key)
{
    if (!localeValid (key))
        return null;
    auto si = key.indexOf ("[");

    // check if this key is language-specific, if not assume untranslated.
    if (si <= 0)
        return "C";

    return key[si+1..$-1];
}

private string getValue (KeyFile kf, string key)
{
    string val;
    try {
        val = kf.getString (DESKTOP_GROUP, key);
    } catch {
        val = null;
    }

    return val;
}

/**
 * Filter out some useless categories which we don't want to have in the
 * AppStream metadata.
 */
string[] filterCategories (string[] cats)
{
    string[] rescats;
    foreach (string cat; cats) {
        switch (cat) {
            case "GTK":
            case "Qt":
            case "GNOME":
            case "KDE":
                break;
            default:
                rescats ~= cat;
        }
    }

    return rescats;
}


bool parseDesktopFile (GeneratorResult res, string fname, string data, bool ignore_nodisplay = false)
{
    auto fname_base = baseName (fname);

    auto df = new KeyFile ();
    try {
        df.loadFromData (data, -1, GKeyFileFlags.KEEP_TRANSLATIONS);
    } catch (Exception e) {
        // there was an error
        res.addHint ("desktop-file-read-error", fname_base, e.msg);
        return false;
    }

    try {
        // check if we should ignore this .desktop file
        auto dtype = df.getString (DESKTOP_GROUP, "Type");
        if (dtype.toLower () != "application") {
            // ignore this file, it isn't describing an application
            return false;
        }
    } catch {}

    try {
        auto nodisplay = df.getString (DESKTOP_GROUP, "NoDisplay");
        if ((!ignore_nodisplay) && (nodisplay.toLower () == "true")) {
                // we ignore this .desktop file, shouldn't be displayed
                return false;
        }
    } catch {}

    try {
        auto asignore = df.getString (DESKTOP_GROUP, "X-AppStream-Ignore");
        if (asignore.toLower () == "true") {
            // this .desktop file should be excluded from AppStream metadata
            return false;
        }
    } catch {
        // we don't care if non-essential tags are missing.
        // if they are not there, the file should be processed.
    }

    /* check this is a valid desktop file */
	if (!df.hasGroup (DESKTOP_GROUP)) {
        res.addHint ("desktop-file-error",
                        fname_base,
                        format ("Desktop file '%s' is not a valid desktop file.", fname));
        return false;
	}

    // make sure we have a valid component to work on
    auto cpt = res.getComponent (fname_base);
    if (cpt is null) {
        cpt = new Component ();
        cpt.setId (fname_base);
        cpt.setKind (ComponentKind.DESKTOP);
        res.addComponent (cpt);
    }

    size_t dummy;
    auto keys = df.getKeys (DESKTOP_GROUP, dummy);
    foreach (string key; keys) {
        string locale;
        locale = getLocaleFromKey (key);
        if (locale is null)
            continue;

        if (key.startsWith ("Name"))
            cpt.setName (getValue (df, key), locale);
        else if (key.startsWith ("Comment"))
            cpt.setSummary (getValue (df, key), locale);
        else if (key == "Categories") {
            auto value = getValue (df, key);
            string[] cats = value.split (";");
            cats = filterCategories (cats);

            cpt.setCategories (cats);
        } else if (key.startsWith ("Keywords")) {
            auto value = getValue (df, key);
            string[] kws = value.split (";");
            kws = kws.stripRight ("");

            cpt.setKeywords (kws, locale);
        } else if (key == "MimeType") {
            auto value = getValue (df, key);
            string[] mts = value.split (";");

            Provided prov = cpt.getProvidedForKind (ProvidedKind.MIMETYPE);
            if (prov is null) {
                prov = new Provided ();
                prov.setKind (ProvidedKind.MIMETYPE);
            }

            foreach (string mt; mts) {
                if (!mt.empty)
                    prov.addItem (mt);
            }
            cpt.addProvided (prov);
        } else if (key == "Icon") {
            auto icon = new Icon ();
            icon.setKind (IconKind.CACHED);
            icon.setName (getValue (df, key));
            cpt.addIcon (icon);
        }
    }

    return true;
}

unittest
{
    import std.stdio;

    auto data = """
[Desktop Entry]
Name=FooBar
Name[de_DE]=FööBär
Comment=A foo-ish bar.
Keywords=Flubber;Test;Meh;
Keywords[de_DE]=Goethe;Schiller;Kant;
""";

    auto res = new GeneratorResult ();
    auto ret = parseDesktopFile (res, "foobar.desktop", data, false);
    assert (ret == true);

    auto cpt = res.getComponent ("foobar.desktop");
    assert (cpt !is null);

    assert (cpt.getName () == "FooBar");
    assert (cpt.getKeywords () == ["Flubber", "Test", "Meh"]);

    cpt.setActiveLocale ("de_DE");
    assert (cpt.getName () == "FööBär");
    assert (cpt.getKeywords () == ["Goethe", "Schiller", "Kant"]);
}
