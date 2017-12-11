#!/usr/bin/env python

# learning Python, why not use it to rewrite NPR's RSS feed for Nina Totenberg
# so it's a podcast again?

feedurl = 'http://www.npr.org/rss/rss.php?id=2101289'
xmlfile = '/tmp/nina.xml'

from bs4 import BeautifulSoup  # for parsing the HTML of the articles
from lxml import etree
import subprocess
import sys, urllib

# download the XML file from the URL and write it to a file
response = urllib.urlopen(feedurl)
data = response.read()
outFile = open(xmlfile, 'w')
outFile.write(data)
outFile.close()

# now use the lxml.etree parser to parse it
doc = etree.parse(xmlfile)
ns = {'content':'http://purl.org/rss/1.0/modules/content/'}

# replace whatever the podcast image is with my own image
for image in doc.xpath('/rss/channel/image/url'):
    image.text = 'http://packy.dardan.com/npr/ninatotenbergtile_sq.png'

# loop over each item in the XML file
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

# re-write the XML to the file we got it from
outFile = open(xmlfile, 'w')
doc.write(outFile)

# copy the file up to my webserver so my phone can get it
p = subprocess.Popen([ 'scp', xmlfile, 'dardanco@www.dardan.com:www/packy/npr/' ])
sts = p.wait
