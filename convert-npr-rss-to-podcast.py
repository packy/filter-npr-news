#!/usr/bin/env python

# learning Python, why not use it to rewrite NPR's RSS feed for Nina Totenberg
# so it's a podcast again?

from bs4 import BeautifulSoup  # for parsing the HTML of the articles
from lxml import etree
import subprocess
import sys, urllib

feedurl = 'http://www.npr.org/rss/rss.php?id=2101289'
xmlfile = '/tmp/nina.xml'

doc = etree.parse(feedurl)
ns = {'content':'http://purl.org/rss/1.0/modules/content/'}

for item in doc.xpath('/rss/channel/item'):

    # the content is CDATA coming in, but unless I explicitly make it
    # CDATA, it isn't CDATA when I re-write the document
    content = item.xpath('.//content:encoded', namespaces=ns)[0]
    content.text = etree.CDATA(content.text)

    # get the link of the article
    link  = item.xpath('./link/text()')[0]

    # parse the article
    soup = BeautifulSoup(urllib.urlopen(link), 'html.parser')

    # find the link to the audio
    tag = soup.body.find('a', class_="audio-module-listen")

    # put this in a try/catch block, because not all articles have audio
    try:
        url = tag.get('href')
        # if we found a link, create an enclosure in the item's XML for it
        enclosure = etree.Element("enclosure", url=url, type="audio/mpeg")
        item.append(enclosure)
    except:
        pass

# re-write the XML to a file!
outFile = open(xmlfile, 'w')
doc.write(outFile)

p = subprocess.Popen([ 'scp', xmlfile, 'dardanco@www.dardan.com:www/packy/npr/' ])
sts = p.wait
